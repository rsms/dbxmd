#pragma once
#include "index.hh"
namespace dbxmd {

using std::string;

struct RecentsIndex : Index {
  static RecentsIndex* sharedInstance();
  RecentsIndex() : Index{"recents"} {}
  const string& version() const;
  void map(const string& path, const Json&);

  Iterator newIterator(leveldb::DB*) const;
};

} // namespace
