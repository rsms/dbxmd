#pragma once
#include "index.hh"
namespace dbxmd {

using std::string;

struct SearchIndex : Index {
  static SearchIndex* sharedInstance();
  SearchIndex() : Index{"search"} {}

  // Implements Index:
  const string& version() const { static string v{"1"}; return v; }
  void map(const string& path, const Json&);

  bool index_file_entry(
    const string& canonical_path,
    const Json&,
    leveldb::WriteBatch&);

  Dropbox::SearchResults search_sync(
    leveldb::DB*       db,
    const std::string& type,
    const std::string& text,
    u32                limit) const;
};

} // namespace
