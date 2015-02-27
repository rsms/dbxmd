#include "str.hh"
#include "unittest.hh"

namespace dbxmd {

string str_trim(const string& s, const string& charset) {
  auto a = s.find_first_not_of(charset);
  if (a == string::npos) a = 0;
  auto b = s.find_last_not_of(charset);
  if (b == string::npos) b = s.size();
  return s.substr(a, b-a);
}


string str_join(const vector<string>& v, const string& glue) {
  string r;
  if (!v.empty()) {
    r.reserve((glue.size() + v[0].size()) * v.size());
    bool first = true;
    for (auto& s : v) {
      if (first) {
        first = false;
        r += s;
      } else {
        r += glue;
        r += s;
      }
    }
  }
  return r;
}


vector<string> str_split(const string& s, const string& delim) {
  size_t start = 0, end;
  vector<string> components;
  // "a||b||c"
  while ((end = s.find(delim, start)) != string::npos) {
    components.emplace_back(s, start, end-start);
    start = end + delim.size();
  }
  components.emplace_back(s, start, end-start);
  return components;
}


std::pair<string, string> str_file_ext(const string& filename) {
  auto dotp = filename.rfind('.');
  if (dotp != string::npos) {
    auto slashp = filename.find_last_of('/');
    if (slashp != string::npos && slashp < dotp) {
      return std::pair<string, string>{filename.substr(0, dotp), filename.substr(dotp+1)};
    }
  }
  return std::pair<string, string>{filename, ""};
}


UNIT_TEST(str_split, {
  auto t = [](const string& subject, const string& delim, const vector<string>& expect) {
    auto components = str_split(subject, delim);
    if (components.size() != expect.size()) {
      std::cerr << "components.size(): " << components.size() << std::endl;
      std::cerr << "expect.size():     " << expect.size() << std::endl;
      throw test_failure("components.size() != expect.size()");
    }
    for (size_t i = 0; i != components.size(); ++i) {
      if (components[i] != expect[i]) {
        std::cerr << "components[" << i << "] = \"" << components[i] << "\"" << std::endl;
        std::cerr << "expect[" << i << "]     = \"" << expect[i] << "\"" << std::endl;
        throw test_failure("components[i] != expect[i]");
      }
    }
    // std::cerr << "test_str_split(\"" << subject << "\") => ";
    // if (components.empty()) {
    //   std::cerr << "[]" << std::endl;
    // } else {
    //   std::cerr << "[\"";
    //   bool is_first = true;
    //   for (auto& s : components) {
    //     if (is_first) {
    //       std::cerr << s;
    //       is_first = false;
    //     } else {
    //       std::cerr << "\", \"" << s;
    //     }
    //   }
    //   std::cerr << "\"]" << std::endl;
    // }
  };

  t("foo/bar/baz", "/", vector<string>{"foo","bar","baz"});
  t("", "/", vector<string>{""});
  t("/", "/", vector<string>{"",""});
  t("/foo//bar/", "/", vector<string>{"","foo","","bar",""});

  t("foo~!bar~!baz", "~!", vector<string>{"foo","bar","baz"});
  t("", "~!", vector<string>{""});
  t("~!", "~!", vector<string>{"",""});
  t("~!foo~!~!bar~!", "~!", vector<string>{"","foo","","bar",""});
})


} // namespace
