#include <rx/rx.h>
#include <leveldb/db.h>
#include <leveldb/write_batch.h>
#include "db.hh"
namespace dbxmd {


void db_foreach(
    leveldb::DB* db,
    const leveldb::Slice& key_prefix,
    rx::func<bool(const leveldb::Slice& key, const leveldb::Slice& value)> fun)
{
  auto ropt = leveldb::ReadOptions();
  db_foreach(db, ropt, key_prefix, fun);
}
  

void db_foreach(
   leveldb::DB* db,
   leveldb::ReadOptions& read_options,
   const leveldb::Slice& key_prefix,
   rx::func<bool(const leveldb::Slice& key, const leveldb::Slice& value)> fun)
{
  leveldb::Iterator* it = db->NewIterator(read_options);
  if (key_prefix.size() == 0) {
    for (it->SeekToFirst(); it->Valid(); it->Next()) {
      if (!fun(it->key(), it->value())) { break; }
    }
  } else {
    for (it->Seek(key_prefix); it->Valid() && it->key().starts_with(key_prefix); it->Next()) {
      if (!fun(it->key(), it->value())) { break; }
    }
  }
}


void db_delete_all(leveldb::DB* db, leveldb::WriteBatch& batch) {
  leveldb::Iterator* it = db->NewIterator(leveldb::ReadOptions());
  for (it->SeekToFirst(); it->Valid(); it->Next()) {
    batch.Delete(it->key());
  }
}


} // namespace
