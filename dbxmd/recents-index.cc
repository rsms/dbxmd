#include <iostream>
#include <ctime>
//#include <time.h>
#include "dbxmd.h"
#include "keyspace.hh"
#include "recents-index.hh"
#include "iterator_imp.hh"
// #include "dropbox_imp.hh"
// #include "db.hh"
 #include "unittest.hh"
// #include "str.hh"

namespace dbxmd {

using std::string;

static const string kReverseKeyPrefix{"keys:"};
static const string kModifiedKeyPrefix{"modified:"};
static const string kVersion{"3"};


const string& RecentsIndex::version() const { return kVersion; }


RecentsIndex* RecentsIndex::sharedInstance() {
  static RecentsIndex* p = nullptr;
  if (p == nullptr) {
    p = new RecentsIndex{};
  }
  return p;
}


static string parseDropboxDate(const string& date) {
  struct tm tm;
  // Fri, 23 Jan 2015 22:15:17 +0000
  if (strptime(date.c_str(), "%a, %d %b %Y %H:%M:%S %z", &tm)) {
    string ts;
    ts.reserve(20);
    ts.resize(19);
    auto t = mktime(&tm);
    auto* tmutc = gmtime(&t);

    // 2015-01-23 22:15:17
    strftime((char*)ts.data(), 20, "%Y-%m-%d %H:%M:%S", tmutc);
    return ts;
  }
  return string{};
}


void RecentsIndex::map(const string& ID, const Json& json) {
  if (json["is_dir"].bool_value()) {
    // Don't index directories because they all have empty modifiers, even for
    // directories modified by others. Basically, we can't tell who modified what.
    return;
  }
  auto& modifier = json["modifier"];
  if (modifier.is_null() ||
      std::to_string(int64_t(modifier["uid"].number_value())) == dropbox().uid())
  {
    // Modified by viewer
    auto timeSerial = parseDropboxDate(json["modified"].string_value());
    auto entryKey = timeSerial + '\t' + json["rev"].string_value();

    // See if we should ignore or replace/create an entry
    auto idToEntryMetaKey = "id-to-entry:" + ID;
    auto existingEntryKey = getMeta(idToEntryMetaKey);
    if (existingEntryKey.empty() || existingEntryKey != entryKey) {
      if (!existingEntryKey.empty()) {
        remove(existingEntryKey);
      }
      emit(entryKey, ID);
      putMeta(idToEntryMetaKey, entryKey);
    }
  }
}


Iterator RecentsIndex::newIterator(leveldb::DB* db) const {
  return Iterator{new Iterator::Imp{db, key()}};
}


UNIT_TEST(parseDropboxDate, {
  auto t = [](const string& indate, const string& expect) {
    auto res = parseDropboxDate(indate);
    if (res != expect) {
      std::cerr << "indate = \"" << indate << "\"" << std::endl;
      std::cerr << "result = \"" << res << "\"" << std::endl;
      std::cerr << "expect = \"" << expect << "\"" << std::endl;
      throw test_failure("parseDropboxDate(indate) != expect");
    }
  };

  t("Fri, 23 Jan 2015 22:15:17 +0000", "2015-01-23 22:15:17");
})


} // namespace
