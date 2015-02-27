#pragma once
#include <leveldb/db.h>
#include <leveldb/write_batch.h>
#include <json11/json11.hh>
#include <rx/status.hh>
#include <forward_list>
#include <set>
namespace dbxmd {

using std::string;
using rx::Status;
using json11::Json;

struct Index {
  //————————————————————————————————————————————————————————————————————————————————————————
  // An index subclass must implement the following methods:

  // Returns the current version (any bytes) of the index. When loading the index, the value
  // of this method is compared to that of the stored value: If they don't match, the index
  // is rebuilt. This allows you to change the implementation of the index without resetting
  // the entire database.
  virtual const string& version() const = 0;

  // Called to initialize the index (i.e. first time it's introduced or when version changes.)
  virtual void init() {};

  // Maps a database entry to the index. This method should call emit() to create index entries.
  virtual void map(const string& ID, const Json&) = 0;

  // The Json object passed to map() looks something like this:
  //  { "bytes": 86,
  //    "client_mtime": "Wed, 21 Jan 2015 23:03:58 +0000",
  //    "icon": "page_white",
  //    "is_dir": false,
  //    "mime_type": "text/url",
  //    "modified": "Fri, 23 Jan 2015 22:15:17 +0000",
  //    "modifier": {
  //      "display_name": "John Smith",
  //      "same_team": true,
  //      "uid": 123456
  //    },
  //    "parent_shared_folder_id": "5678901234",
  //    "path": "/dbapp/dbapp-desktop/Postmortems/Yosemite postmortem.url",
  //    "read_only": false,
  //    "rev": "8cdc23804a74",
  //    "revision": 36060,
  //    "root": "dropbox",
  //    "size": "86 bytes",
  //    "thumb_exists": false
  //  }

  //————————————————————————————————————————————————————————————————————————————————————————
  // The following methods are available from within init() and map():

  // Create or set a value in the index
  void emit(const string& key, const leveldb::Slice& value);

  // Read a value from the index
  string get(const string& key);

  // Remove a value from the index
  void remove(const string& key);

  // Read, write or remove a meta value from the index.
  // Meta values are not included when iterating over an index's entries.
  string getMeta(const string& key) const;
  void putMeta(const string& key, const leveldb::Slice& value);
  void removeMeta(const string& key);

  // What Dropbox we are indexing
  const Dropbox& dropbox() const;

  //————————————————————————————————————————————————————————————————————————————————————————
  // The following methods are usually not used by index subclasses

  using List = std::forward_list<Index*>;
  static const List& all();

  Index(const string& name);
  Index(Index&&) = default;

  const string& name() const;
  const string& key() const; // e.g. "index:<name>:"
  string key(const string& suffix) const; // e.g. ("foo") => "index:<name>:foo"
  string read_version(leveldb::DB*) const;

  // Update functions. Warning: Non-reentrant.
  void update_begin(const Dropbox&, leveldb::DB*, leveldb::WriteBatch*);
    void update_init();
    void update_put(const string& ID, const Json&);
    void update_remove(const string& ID);
  void update_end();

  struct UpdateScope {
    UpdateScope(Index& index, const Dropbox& dropbox, leveldb::DB* db, leveldb::WriteBatch* batch)
      : _index{index} { _index.update_begin(dropbox, db, batch); }
    ~UpdateScope() { _index.update_end(); }
  private:
    Index& _index;
  };

  Status rebuild(const Dropbox&, leveldb::DB*);

private:
  Index(const Index&) = delete;
  string _getMeta(leveldb::DB*, const string& key) const;
  void _putMeta(const string& key, const leveldb::Slice& value);
  void _removeMeta(const string& key);

  string               _name;
  string               _key_prefix;
  // Valid only inside map() calls:
  leveldb::DB*         _db = nullptr;
  leveldb::WriteBatch* _batch = nullptr;
  const Dropbox*       _dropbox = nullptr;
  std::set<string>     _keys;
};

//————————————————————————————————————————————————————————————————————————————————————

inline Index::Index(const string& name)
  : _name{name}
  , _key_prefix{"index:"+_name+":"}
  {}
inline const string& Index::name() const { return _name; }
inline const string& Index::key() const { return _key_prefix; }
inline string Index::key(const string& s) const { return _key_prefix + s; }

} // namespace
