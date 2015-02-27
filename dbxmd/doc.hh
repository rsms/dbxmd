#pragma once
#include <json11/json11.hh>
#include <vector>
#include <string>
namespace dbxmd {

using DocID = std::string;

struct DocEntry {
  DocID        ID;
  json11::Json value;
  DocEntry(DocID ID, json11::Json value) : ID{ID}, value{value} {}
};

using DocEntries = std::vector<DocEntry>;

} // namespace
