#import "dbxmd.h"
#import "dropbox_imp.hh"

#import <dispatch/dispatch.h>
#import <Foundation/Foundation.h>
#import <leveldb/filter_policy.h>
#import <iomanip>
#import <forward_list>
#import <dbxapi/dbxapi.hh>

#import "db.hh"
#import "keyspace.hh"
#import "version.hh"
#import "search-index.hh"
#import "recents-index.hh"


namespace dbxmd {

using json11::Json;
using std::string;
using std::vector;
using std::cerr;
using std::clog;
using std::endl;

// ================================================================================================


// static string str_to_lower(const string& s) {
//   return [[NSString alloc] initWithBytesNoCopy:(void*)s.data()
//     length:s.size() encoding:NSUTF8StringEncoding freeWhenDone:NO].lowercaseString.UTF8String;
// }


// #define assert_lowercase_string(std_string) \
//   assert(strcmp(str_to_lower(std_string).c_str(), (std_string).c_str()) == 0)
  

// /*static*/ string Dropbox::Imp::doc_entry_key(const string& path) {
//   assert_lowercase_string(path); // Expects path to be lower-case
//   return kFileEntryKeyPrefix + path;
// }


void Dropbox::Imp::apply_doc_entries(
    const DocEntries& entries,
    leveldb::DB* db,
    leveldb::WriteBatch& batch)
{
  Dropbox dropbox{this, /*add_ref=*/true};

  for (auto* index : Index::all()) {
    index->update_begin(dropbox, db, &batch);
  }

  for (auto& entry : entries) {
    if (entry.value.is_null()) {
      // removed
      batch.Delete(kFileEntryKeyPrefix + entry.ID);
      for (auto* index : Index::all()) {
        index->update_remove(entry.ID);
      }
    } else {
      // added or modified
      batch.Put(kFileEntryKeyPrefix + entry.ID, entry.value.dump());
      for (auto* index : Index::all()) {
        index->update_put(entry.ID, entry.value);
      }
    }
  }

  for (auto* index : Index::all()) {
    index->update_end();
  }
}


static DocEntries dbx_delta_to_doc_entries(const Json& delta) {
  DocEntries entries;
  auto delta_entries = delta["entries"].array_items();
  entries.reserve(delta_entries.size());
  for (auto& entry : delta_entries) {
    auto ID = entry[0].string_value();
    auto value = entry[1];
    entries.emplace_back(ID, value);
  }
  return std::move(entries);
}


Status Dropbox::Imp::apply_dbx_delta(const Json& delta, leveldb::DB* db) {
  // TODO: Handle "reset" case (see https://www.dropbox.com/developers/core/docs#delta)

  // Check `entries`
  Json entries = delta["entries"];
  if (!delta["entries"].is_array()) {
    return Status{"Unexpected data from dbx /delta: entries is not an array"};
  }
  
  leveldb::WriteBatch batch; // database modification transaction
  
  // Introduce changes into db
  auto doc_entries = dbx_delta_to_doc_entries(delta);
  apply_doc_entries(doc_entries, db, batch);
  
  // Finalize
  batch.Put("dbx:delta-cursor", delta["cursor"].string_value());
  auto s = db->Write(leveldb::WriteOptions(), &batch);

  // Notify any change listeners
  if (s.ok() && !data_change_listeners.empty()) {
    notify_data_changes(batch);
  }

  return s.ok() ? Status::OK() : Status{s.ToString()};
}

// ================================================================================================

Dropbox::Imp::Imp(
  const string& uid,
  const std::string& atok,
  const string& path_prefix,
  AuthExpiredCallback auth_expired_cb
)
  : uid{uid}
  , access_token{atok}
  , path_prefix{path_prefix}
  , auth_expired_cb{auth_expired_cb}

  , thread{Thread{
      (__bridge void*)dispatch_queue_create("dbxmd", DISPATCH_QUEUE_SERIAL),
      Thread::Type::DispatchQueue
    }}

  , dbx_api_reachability{
      "api.dropbox.com",
      NetReach::State::Unreachable,
      [=](NetReach::State reachabilityState) {
        if (reachabilityState == NetReach::State::Reachable) {
          if (!dbx_api_is_reachable) {
            clog << "[dbxmd] netreach change: unreachable ➔ reachable" << endl;
            // typically receive a reachable message ~20ms before the unreachable one
            dbx_api_is_reachable = true;
            if (once_dbx_api_became_reachable != nullptr) {
              thread.async(once_dbx_api_became_reachable);
              once_dbx_api_became_reachable = nullptr;
            }
          }
        } else {
          clog << "[dbxmd] netreach change: reachable ➔ unreachable" << endl;
          dbx_api_is_reachable = false;
        }
      }
    }

  , state{

  {"offline", [=] {
    // assert(once_dbx_api_became_reachable == nullptr);
    once_dbx_api_became_reachable = state.deferred("switch");
  }},

  {"invalid_auth", [=] {
    if (!auth_expired_cb) {
      // This is the end
      NSLog(@"[dbxmd] invalid auth -- stopping");
    } else {
      reauthenticate();
    }
  }},

  {"api_error", [=] {
    auto status = last_api_status;
    last_api_status = Status::OK();

    switch (status.code()) {
      case dbxapi::StatusCodeNotConnected: {
        inc_api_back_off_time(0.2, 1);
        break;
      }

      // case StatusCodeTimeout
      //   retry immediately

      case dbxapi::StatusCodeAPIRequestError: {
        reset_delta_cursor(); // Note: only resets the cursor, not the data.
        delta_has_more = true; // FIXME shouldn't this be set in dbx_delta?
        break;
      }

      case dbxapi::StatusCodeAPIRequestUnauthorized: {
        state("invalid_auth");
        return;
      }

      case dbxapi::StatusCodeAPIRequestRateLimit: {
        api_back_off_time = std::stod(status.message());
        if (api_back_off_time <= 0.0 || isnan(api_back_off_time) || isinf(api_back_off_time)) {
          inc_api_back_off_time(5, 30);
        }
        break;
      }

      case dbxapi::StatusCodeAPIServerError: {
        inc_api_back_off_time(1, 5);
        break;
      }

      case dbxapi::StatusCodeResponseError: {
        inc_api_back_off_time(0.5, 5);
        break;
      }

      case dbxapi::StatusCodeConnectionError: {
        inc_api_back_off_time(0.5, 5);
        break;
      }
    }

    state("switch");
  }},

  {"switch", [=]() mutable {
    if (last_api_status.ok() || !dbx_api_is_reachable) {
      api_back_off_time = 0;
    }
    if (!dbx_api_is_reachable)      state("offline");
    else if (!last_api_status.ok()) state("api_error");
    else if (delta_has_more)        state("delta_get");
    else                            state("delta_wait");
  }},
  
  {"delta_get", [=] {
    delta_get(state.deferredWithStatus("switch"));
  }},
  
  {"delta_wait", [=] {
    delta_wait(state.deferredWithStatus("switch"));
  }},

  {"entry", [=] { state("switch"); }},
}{
  state.should_transition = [](const string& from, const string& to) {
    if (!from.empty()) {
      clog << "[dbxmd] state transition " << std::setw(12) << from << " ➔ " << to << endl;
    }
    return true;
  };
  dbx_api_is_reachable = dbx_api_reachability.isReachable();
}


void Dropbox::Imp::inc_api_back_off_time(double seconds_min, double seconds_max) {
  if (api_back_off_time <= 0) {
    api_back_off_time = seconds_min;
  } else {
    api_back_off_time = RX_MIN(api_back_off_time * 2, seconds_max);
  }
}


void Dropbox::Imp::reauthenticate() {
  NSLog(@"[dbxmd] reauthenticating");
  Dropbox ref{this, /*add_ref=*/true};
  auth_expired_cb([ref](const string& access_token) {
    if (access_token.empty()) {
      NSLog(@"[dbxmd] reauthentication aborted -- stopping");
      // This is the end
    } else {
      ref->access_token = access_token;
      ref->thread.async([ref] {
        NSLog(@"[dbxmd] reauthentication successful -- resuming");
        ref->state("switch");
      });
    }
  });
}


void Dropbox::Imp::reset_delta_cursor() {
  db->Delete(leveldb::WriteOptions{}, "dbx:delta-cursor");
}


void Dropbox::Imp::start() {
  // Rebuild indexes as needed
  Dropbox dropbox{this, /*add_ref=*/true};
  for (auto* index : Index::all()) {
    if (index->read_version(db) != index->version()) {
      index->rebuild(dropbox, db);
    }
  }

  // auto it = RecentsIndex::sharedInstance()->newIterator(db);
  // // for (it.seekToKey("2014-"); it.valid(); it.prev()) {
  // size_t n = 10;
  // for (it.seekToLast(); it.valid() && --n; it.prev()) {
  //   clog << "  \"" << it.key() << "\" => \"" << it.entryValue() << "\"" << endl;
  // }

  // DEBUG XXX
  // add_data_change_listener("fn:", [](const Dropbox::Imp::DataChanges& changes) {
  //   clog << "listener 'fn:'1" << endl;
  // });
  // add_data_change_listener("fn:", [](const Dropbox::Imp::DataChanges& changes) {
  //   clog << "listener 'fn:'2" << endl;
  //   for (auto& change : changes) {
  //     clog << change.key.ToString() << ",";
  //   }
  //   clog << endl;
  // });
  // add_data_change_listener("index:search:", [](const Dropbox::Imp::DataChanges& changes) {
  //   clog << "listener 'index:search:'" << endl;
  //   for (auto& change : changes) {
  //     clog << change.key.ToString() << ",";
  //   }
  //   clog << endl;
  // });

  state("entry");
}


void Dropbox::__dealloc(Dropbox::Imp* p) { delete p; }


Dropbox::Imp::~Imp() {
  clog << "Dropbox::Imp::~Imp()" << endl;
  if (db) {
    delete db;
  }
  if (db_options.filter_policy) {
    delete db_options.filter_policy;
  }
}


Dropbox::Dropbox(
  const string& uid,
  const string& access_token,
  const string& path_prefix,
  AuthExpiredCallback auth_expired_cb
)
  : self{new Imp{uid, access_token, path_prefix, auth_expired_cb}}
{}


Status Dropbox::open(const string& data_dirname) {
  assert(self->db == nullptr);

  string db_path = data_dirname + "/" + self->uid + ".dbxmd";

  // Create directories if needed
  NSError* error;
  BOOL dirCreated = [[NSFileManager defaultManager] 
    createDirectoryAtPath:[NSString stringWithUTF8String:db_path.c_str()]
      withIntermediateDirectories:YES attributes:nil error:&error];
  if (!dirCreated) {
    return Status{
      string{"Failed to create data directory at '"} + db_path + "': " +
      error.localizedDescription.UTF8String
    };
  }

  bool did_retry = false;
  bool did_reset_db = false;

opendb:
  // Open database
  self->db_options.create_if_missing = true;
  // BloomFilterPolicy: Cache N bits per key in memory:
  self->db_options.filter_policy = leveldb::NewBloomFilterPolicy(32);
  auto st = leveldb::DB::Open(self->db_options, db_path, &self->db);

  if (!st.ok()) {
    clog << "[dbxmd] open failure: " << st.ToString() << endl;
    if (!did_retry) {
      did_retry = true;
      if (RepairDB(db_path, self->db_options).ok()) {
        goto opendb;
      } else {
        DestroyDB(db_path, self->db_options);
        did_reset_db = true;
        goto opendb;
      }
    }
    return Status{string{"failed to open leveldb database: "} + st.ToString()};

  } else if (did_reset_db) {
    self->db->Put(leveldb::WriteOptions{}, "g:dbversion", kDatabaseVersion);

  } else {
    // Check version
    string dbversion;
    st = self->db->Get(leveldb::ReadOptions{}, "g:dbversion", &dbversion);
    if (dbversion != kDatabaseVersion) {
      clog << "[dbxmd] resetting local storage (version mismatch: stored=\""
           << dbversion << "\", program=\"" << kDatabaseVersion << "\")" << endl;
      delete self->db;
      DestroyDB(db_path, self->db_options);
      did_reset_db = true;
      goto opendb;
    } else {
      clog << "[dbxmd] storage version " << dbversion << endl;
    }
  }

  // db_foreach(self->db, "", [&](const leveldb::Slice& key, const leveldb::Slice& value) {
  //   clog << "\"" << key.ToString() << "\":" << value.ToString() << "," << endl;
  //   return true;
  // });

  // Schedule dbx API endpoint network reachability observer
  self->dbx_api_reachability.resume();

  auto s = *this;
  self->thread.async([=]{
    s->start();
  });

  return Status::OK();
}


const string& Dropbox::uid() const {
  assert(self != nullptr);
  return self->uid;
}


const string& Dropbox::access_token() const {
  assert(self != nullptr);
  return self->access_token;
}


void Dropbox::Imp::delta_get(rx::func<void(Status)> cb) {
  if (api_back_off_time != 0) {
    std::cout << "delta_get: backing off for " << api_back_off_time << " seconds" << endl;
    Timer::startTimeout(api_back_off_time, thread, [=]{ delta_get(cb); });
    return;
  }
  assert(delta_has_more);
  string cursor;
  db->Get(leveldb::ReadOptions(), "dbx:delta-cursor", &cursor);
  Dropbox dbx{this, /*add_ref=*/true};
  dbxapi::delta_get(access_token, path_prefix, cursor, [dbx,cb,cursor](rx::Status st, Json json) {
    dbx->thread.async([=]{
      dbx->last_api_status = st;
      // if (json["reset"].bool_value()) 
      //   TODO: Dropbox wants us to clear the database here ... Really?
      if (!st.ok()) {
        cb(st);
      } else {
        // std::cout << "dbx_delta_get -> " << json.dump() << endl;
        auto st = dbx->apply_dbx_delta(json, dbx->db);
        if (!st.ok()) {
          cb(st);
        } else {
          dbx->delta_has_more = json["has_more"].bool_value();
          cb(nullptr);
        }
      }
    });
  });
}

  
void Dropbox::Imp::delta_wait(rx::func<void(Status)> cb) {
  assert(!delta_has_more);
  string cursor;
  db->Get(leveldb::ReadOptions(), "dbx:delta-cursor", &cursor);
  dbxapi::delta_wait(access_token, cursor, [=](rx::Status st, Json json) {
    last_api_status = st;
    if (!st.ok()) {
      cb(st);
    } else {
      delta_has_more = json["changes"].bool_value();
      cb(nullptr);
    }
  });
}


Dropbox::SearchResults Dropbox::search(
  const string& type,
  const string& text,
  u32 limit) const
{
  return SearchIndex::sharedInstance()->search_sync(self->db, type, text, limit);
}


const string& Dropbox::searchDataKey() const {
  return SearchIndex::sharedInstance()->key();
}


Iterator Dropbox::newRecentsIterator() const {
  return RecentsIndex::sharedInstance()->newIterator(self->db);
}


const string& Dropbox::recentsDataKey() const {
  return RecentsIndex::sharedInstance()->key();
}


ListenerID Dropbox::addChangeListener(const string& keyPrefix, DataChangeListener listener) {
  std::lock_guard<std::mutex> lock(self->data_change_listeners_mu);
  auto& listeners = self->data_change_listeners[keyPrefix + "\xff"];
  listeners.emplace_back(listener);
  return (ListenerID)&listeners.back();
}


void Dropbox::removeChangeListener(const string& keyPrefix, ListenerID ident) {
  std::lock_guard<std::mutex> lock(self->data_change_listeners_mu);
  auto I = self->data_change_listeners.find(keyPrefix + "\xff");
  if (I != self->data_change_listeners.end()) {
    auto& listeners = I->second;
  find_listener:
    auto it = listeners.begin();
    for (; it != listeners.end(); it++) {
      auto& listener = *it;
      if (ident == (ListenerID)&listener) {
        listeners.erase(it);
        goto find_listener;
      }
    }
    if (listeners.empty()) {
      self->data_change_listeners.erase(I);
    }
  }
}


using ChangesMap = std::map<string, DataChanges>;

struct DBBatchChangeVisitor : leveldb::WriteBatch::Handler {
  const Dropbox::Imp::DataChangeListeners& listeners;
  ChangesMap                               changes_map;

  DBBatchChangeVisitor(const Dropbox::Imp::DataChangeListeners& listeners) : listeners{listeners} {}

  void add_change(const leveldb::Slice& key, DataChange::Kind kind) {
    auto p = listeners.upper_bound(key.ToString());
    if (p != listeners.end()) {
      changes_map[p->first].emplace_back(key, kind);
    }
  }

  void Put(const leveldb::Slice& key, const leveldb::Slice& value) {
    // clog << "PUT " << key.ToString() << endl;
    add_change(key, DataChange::Modified);
  }

  void Delete(const leveldb::Slice& key) {
    // clog << "DEL " << key.ToString() << endl;
    add_change(key, DataChange::Removed);
  }
};


void Dropbox::Imp::notify_data_changes(const leveldb::WriteBatch& batch) {
  std::lock_guard<std::mutex> lock(data_change_listeners_mu);
  DBBatchChangeVisitor visitor{data_change_listeners};
  batch.Iterate(&visitor);

  for (auto& change : visitor.changes_map) {
    auto& keyPrefix = change.first;
    auto& changes = change.second;
    auto listeners = data_change_listeners.find(keyPrefix);
    if (listeners != data_change_listeners.end()) {
      for (auto& listener : listeners->second) {
        listener(changes);
      }
    }
  }
}


// struct SliceLess {
//   bool operator()(const leveldb::Slice &lhs, const leveldb::Slice &rhs) const {
//     return lhs.compare(rhs);
//   }
// };
// using SliceToDataChangesMap = std::map<leveldb::Slice, Dropbox::Imp::DataChanges, SliceLess>;


} // namespace
