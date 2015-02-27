#pragma once
namespace dbxmd {

struct Iterator::Imp : rx::ref_counted_novtable {
  leveldb::DB*         db;
  leveldb::Iterator*   it;
  leveldb::ReadOptions read_options;
  string               key_prefix;
  string               key_prefix_terminal;
  leveldb::Slice       key_prefix_terminal_slice;

  Imp(leveldb::DB* db, const string& key_prefix)
    : db{db}
    , key_prefix{key_prefix}
    , key_prefix_terminal{key_prefix + "\xff"}
    , key_prefix_terminal_slice{key_prefix_terminal}
  {
    read_options.snapshot = db->GetSnapshot();
    it = db->NewIterator(read_options);
  }

  ~Imp() {
    db->ReleaseSnapshot(read_options.snapshot);
    delete it;
  }
};

} // namespace
