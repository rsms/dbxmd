#include <leveldb/write_batch.h>
#include <json11/json11.hh>
#include <iostream>
#include "dbxmd.h"
#include "index.hh"
#include "search-index.hh"
#include "recents-index.hh"
#include "keyspace.hh"
#include "db.hh"

namespace dbxmd {


// 0xff so that iteration never reaches meta values
static const string kMetaKeyPrefix{"\xff"};

static const string kMetaVersionKey{"_version_"};
static const string kMetaReverseLookupKeyPrefix{"_keys_:"};

static Index::List gAllIndexes{
  SearchIndex::sharedInstance(),
  RecentsIndex::sharedInstance(),
};

const Index::List& Index::all() {
  return gAllIndexes;
}


string Index::read_version(leveldb::DB* db) const {
  return _getMeta(db, kMetaVersionKey);
}


void Index::update_begin(const Dropbox& dropbox, leveldb::DB* db, leveldb::WriteBatch* batch) {
  _db = db;
  _batch = batch;
  _dropbox = &dropbox;
}

void Index::update_end() {
  _db = nullptr;
  _batch = nullptr;
  _dropbox = nullptr;
  _keys.clear();
}


void Index::update_init() {
  // Add key terminal
  _batch->Put(key(kMetaKeyPrefix), leveldb::Slice{});

  // Invoke init method
  init();
}


void Index::update_put(const string& ID, const Json& obj) {
  map(ID, obj);
  if (!_keys.empty()) {
    _putMeta(kMetaReverseLookupKeyPrefix + ID, Json{_keys}.dump());
    _keys.clear();
  }
}


void Index::update_remove(const string& ID) {
  // entry was removed; read reverse keys and remove those entries
  string rvs = getMeta(kMetaReverseLookupKeyPrefix + ID);
  if (!rvs.empty()) {
    string err;
    auto rv = Json::parse(rvs, err);
    for (auto& item : rv.array_items()) {
      _batch->Delete(key(item.string_value()));
    }
  }
  // ... and remove the reverse key list itself
  _removeMeta(kMetaReverseLookupKeyPrefix + ID);
}


void Index::emit(const string& k, const leveldb::Slice& value) {
  assert(_batch != nullptr);
  _batch->Put(key(k), value);
  _keys.emplace(std::move(k));
}


void Index::remove(const string& k) {
  assert(_batch != nullptr);
  _batch->Delete(key(k));
  _keys.erase(k);
}


string Index::get(const string& k) {
  assert(_db != nullptr);
  string v;
  _db->Get(leveldb::ReadOptions(), key(k), &v);
  return std::move(v);
}


string Index::getMeta(const string& k) const {
  assert(_db != nullptr);
  return _getMeta(_db, k);
}

void Index::putMeta(const string& k, const leveldb::Slice& value) {
  _putMeta(k, value);
  _keys.emplace(std::move(k));
}

void Index::removeMeta(const string& k) {
  _removeMeta(k);
  _keys.erase(k);
}

string Index::_getMeta(leveldb::DB* db, const string& k) const {
  string v;
  db->Get(leveldb::ReadOptions(), key(kMetaKeyPrefix + k), &v);
  return std::move(v);
}

void Index::_putMeta(const string& k, const leveldb::Slice& value) {
  assert(_batch != nullptr);
  _batch->Put(key(kMetaKeyPrefix + k), value);
}

void Index::_removeMeta(const string& k) {
  assert(_batch != nullptr);
  _batch->Delete(key(kMetaKeyPrefix + k));
}



const Dropbox& Index::dropbox() const {
  assert(_dropbox != nullptr);
  return *_dropbox;
}


Status Index::rebuild(const Dropbox& dropbox, leveldb::DB* db) {
  std::clog << "[dbxmd] rebuilding index \"" << name() << "\" ..." << std::endl;

  leveldb::WriteBatch batch;
  UpdateScope updateScope{*this, dropbox, db, &batch};

  // First delete any existing index entries
  db_foreach(
    db,
    key(),
    [&](const leveldb::Slice& key, const leveldb::Slice& value) {
      batch.Delete(key);
      return true;
    }
  );
  
  // Init
  update_init();

  // Set version
  _putMeta(kMetaVersionKey, version());

  // TODO: run in chunks to save on memory
  //   1. instead of using db_foreach, get an iterator to file entries and
  //   2. map N entries, then
  //   3. db->Write(batch), if iterator is valid goto 2, else
  //   4. complete

  // Build indexes from file entries
  db_foreach(
    db,
    kFileEntryKeyPrefix,
    [&](const leveldb::Slice& key, const leveldb::Slice& value) {
      // std::cout << "F " << key.ToString() << " = " << value.ToString() << std::endl;
      string err;
      auto jsonValue = Json::parse(value.ToString(), err);
      if (jsonValue.is_object()) {
        string ID{
          key.data() + kFileEntryKeyPrefix.size(),
          key.size() - kFileEntryKeyPrefix.size()
        };
        update_put(ID, jsonValue);
      }
      return true;
    }
  );

  // Commit
  auto s = db->Write(leveldb::WriteOptions(), &batch);
  std::clog << "[dbxmd] rebuilding index \"" << name() << "\"";
  if (s.ok()) {
    std::clog << " completed" << std::endl;
  } else {
    std::clog << " failed: " << s.ToString() << std::endl;
  }
  return s.ok() ? Status::OK() : Status{s.ToString()};
}


} // namespace
