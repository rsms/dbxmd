#pragma once
#include <string>
#include <vector>
namespace dbxmd {

using std::string;
using std::vector;

string str_trim(const string& s, const string& charset);

string str_join(const vector<string>& v, const string& glue);

vector<string> str_split(const string& s, const string& delim);

// Returns first=(filename without extension), second=(extension)
// E.g. ("foo/bar.baz") => {first="foo/bar", second="baz"}
std::pair<string, string> str_file_ext(const string& filename);

} // namespace
