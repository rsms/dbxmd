#pragma once
namespace dbxmd {

void db_foreach(
  leveldb::DB* db,
  const leveldb::Slice& key_prefix,
  rx::func<bool(const leveldb::Slice& key, const leveldb::Slice& value)> fun);


void db_foreach(
  leveldb::DB* db,
  leveldb::ReadOptions& read_options,
  const leveldb::Slice& key_prefix,
  rx::func<bool(const leveldb::Slice& key, const leveldb::Slice& value)> fun);

// Danger zone
void db_delete_all(leveldb::DB*, leveldb::WriteBatch&);

} // namespace
