#include "dbxmd.h"
#include <Foundation/Foundation.h>

#include "keyspace.hh"
#include "search-index.hh"
#include "dropbox_imp.hh"
#include "db.hh"
#include "str.hh"

namespace dbxmd {

using std::vector;
using std::string;

// #define TRACELINE std::cerr << "T " << __LINE__ << std::endl;

static const string kBasenameKeyPrefix{"b:"};
static const string kNameKeyPrefix{"n:"};
static const string kTypeKeyPrefix{"t:"};
static const string kReverseKeyPrefix{"r:"};


static NSCharacterSet* term_separator_charset() {
  static NSMutableCharacterSet* cs;
  static dispatch_once_t onceToken; dispatch_once(&onceToken, ^{
    //NSString* quotesString =
    //   @"\"'\u201c\u201d\u2018\u2019\u201b\u201f\u201a\u201e\u275b\u275c\u275d\u275e";
    cs = [[NSCharacterSet punctuationCharacterSet] mutableCopy];
    [cs formUnionWithCharacterSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [cs formUnionWithCharacterSet:[NSCharacterSet illegalCharacterSet]];
  });
  return cs;
}


static NSString* NSStringFromCPPString(const string& s) {
  return [[NSString alloc] initWithBytes:(void*)s.data()
    length:s.size() encoding:NSUTF8StringEncoding];
}


//static string str_to_lower(const string& s) {
//  auto* str = [[NSString alloc] initWithBytesNoCopy:(void*)s.data()
//    length:s.size() encoding:NSUTF8StringEncoding freeWhenDone:NO].lowercaseString;
//  return string{str.UTF8String};
//}


SearchIndex* SearchIndex::sharedInstance() {
  static SearchIndex* p = nullptr;
  if (p == nullptr) {
    p = new SearchIndex{};
  }
  return p;
}


void SearchIndex::map(const string& canonical_path, const Json& json) {
  static NSCharacterSet* kCharacterSetForTrimming = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    kCharacterSetForTrimming = [NSCharacterSet characterSetWithCharactersInString:@"/"];
  });

  // TODO: Use mtime as a ranking factor

  auto path = str_trim(canonical_path, "/");
  if (path.size() == 0) {
    // Special case where path is "/"
    return;
  }
  
  // terms in basename
  auto pathv = str_split(path, "/");
  u64 depth = pathv.size() * 10;
  auto dirname = pathv.size() > 1 ?
    str_join(vector<string>{pathv.cbegin(), pathv.cend()-1}, "/")
    : string{};
  auto basename = pathv[pathv.size()-1];

  // Unicode-aware term separation
  NSArray* basename_terms = [NSStringFromCPPString(basename)
    componentsSeparatedByCharactersInSet:term_separator_charset()];
  NSArray* dirname_terms = dirname.empty() ? @[] :
    [NSStringFromCPPString(dirname)
      componentsSeparatedByCharactersInSet:term_separator_charset()];
  
  // Helper for adding a term index
  auto add_term_index = [&](const char* term, u64 depth) {
    auto k = kNameKeyPrefix + term + ' ' + std::to_string(depth) + ' ' + canonical_path;
      // TODO FIXME: std::to_string(depth) is flawed since leveldb uses binary comparison for
      //             sorting. This means that "a 199" comes before "a 20".
    emit(k, "");
    //std::cout << "  - " << k << std::endl;
  };
  
  // Basename (e.g. "/lol/cat/foo bar.txt" -> "i:b:foo bar.txt 123 /lol/cat/bar.txt")
  auto k = kBasenameKeyPrefix + basename + ' ' + std::to_string(depth) + ' ' + canonical_path;
  emit(k, "");

  // Type name
  string type_name;
  if (json["is_dir"].bool_value()) {
    type_name = "/";
  } else {
    // Note: Can't use NSString because it bails on some messed up non-unicode filenames.
    auto p = str_file_ext(basename);
    if (NSStringFromCPPString(basename) == nullptr) {
      std::cerr << "NSStringFromCPPString(\"" << basename << "\") => nullptr" << std::endl;
      for (auto& s : pathv) {
        std::cerr << "  pathv[] = \"" << s << "\"" << std::endl;
      }
      std::cerr << "str_file_ext(\"" << basename << "\") => {\"" << p.first << "\", \"" << p.second << "\"}" << std::endl;
    }
    basename = p.first;
    type_name = p.second;

    // Add type name as a "term" as well, with a dot prefix
    add_term_index((string(".") + type_name).c_str(), depth + 1000);
  }

  // Basename terms
  for (NSString* term in basename_terms) {
    add_term_index(term.UTF8String, depth);
    
    // Type-prefixed (currently unused, and maybe this is a stupid idea)
    //auto tk = kTypeKeyPrefix + type_name + ' ' + term.UTF8String +
    //  ' ' + std::to_string(depth) + ' ' + canonical_path;
    //emit(tk, "");
    
    ++depth;
  }
  
  // Dirname terms
  depth = 1000; // demote pathname terms
  for (NSString* term in dirname_terms) {
    add_term_index(term.UTF8String, depth++);
  }
  
  // TODO: We could store a curated score as the value for these entries. It could be bumped by
  // the user taking an action, say opening a file that she found via an entry returned from a
  // search query.
}


// ================================================================================================
// Searching


static NSCharacterSet* term_separator_charset_for_querying() {
  static NSMutableCharacterSet* cs;
  static dispatch_once_t onceToken; dispatch_once(&onceToken, ^{
    cs = [term_separator_charset() mutableCopy];
    [cs removeCharactersInString:@".-"];
      // allow dot for e.g. ".pdf"
      // allow minus for logical-NOT terms
  });
  return cs;
}


template <typename T>
static void RX_UNUSED dump_collection(const char* name, const T& collection) {
  std::cout << name << ":" << std::endl;
  size_t i = 0;
  for (auto& value : collection) { std::cout << "  " << i++ << " = " << value << std::endl; }
  std::cout << std::endl;
}


static string normalize_term_text(const string& text) {
  return [[NSString alloc] initWithBytesNoCopy:(void*)text.data()
    length:text.size() encoding:NSUTF8StringEncoding freeWhenDone:NO].lowercaseString.UTF8String;
}


// static vector<string> split_terms(const string& text) {
//   vector<string> terms;
//   NSArray* termsnsarray =
//     [[[NSString alloc] initWithBytesNoCopy:(void*)text.data()
//       length:text.size()
//       encoding:NSUTF8StringEncoding freeWhenDone:NO].lowercaseString
//     componentsSeparatedByCharactersInSet:term_separator_charset_for_querying()];
//   terms.reserve(termsnsarray.length);
//   for (NSString* t in termsnsarray) {
//     if (t.length != 0) {
//       terms.emplace_back(t.UTF8String);
//     }
//   }
//   return terms;
// }


static std::pair<size_t,size_t> parse_terms(
  const string& text,
  std::forward_list<string>& terms)
{
  // Returns a pair of term count: {positive_count, negative_count}

  NSArray* termsnsarray =
    [[[NSString alloc] initWithBytesNoCopy:(void*)text.data()
      length:text.size()
      encoding:NSUTF8StringEncoding freeWhenDone:NO].lowercaseString
    componentsSeparatedByCharactersInSet:term_separator_charset_for_querying()];

  std::forward_list<string> negative_terms; // later added to end of terms
  auto terms_tail = terms.before_begin();
  auto negative_terms_tail = negative_terms.before_begin();
  std::set<string> seen_terms;
  size_t n_positive_terms = 0;

  for (NSString* t in termsnsarray) {
    if ( t.length != 0 && (t.length > 1 || [t characterAtIndex:0] != '-') ) {
      // ^~~ Special case: Negative term w/o an actual term. i.e. "-"
      auto I = seen_terms.emplace(t.UTF8String);
      if (I.second) {
        // Never-seen-before term
        const string& term = *I.first;
        if (term[0] == '-') {
          negative_terms_tail = negative_terms.emplace_after(negative_terms_tail, term);
        } else {
          terms_tail = terms.emplace_after(terms_tail, term);
          ++n_positive_terms;
        }
      }
    }
  }
  
  if (!negative_terms.empty()) {
    terms.splice_after(terms_tail, std::move(negative_terms));
  }
  
  return {n_positive_terms, seen_terms.size()-n_positive_terms}; // {positive_count, nnegative_count}
}


Dropbox::SearchResults SearchIndex::search_sync(
  leveldb::DB*       db,
  const string& type,
  const string& text,
  u32                limit) const
{
  // Parse and collect terms from text
  std::forward_list<string> terms;
  auto nterms = parse_terms(text, terms);
  auto nterms_pos = nterms.first, nterms_neg = nterms.second;
  //dump_collection("terms", terms);
  
  // essentially we will consider no more than (limit*look_ahead_factor) items
  const u32 look_ahead_factor = 100;

  // No positive terms? No results.
  if (nterms_pos == 0) {
    return Dropbox::SearchResults{};
  }
  
  auto path_from_index_key = [](const leveldb::Slice& key) {
    // TODO: When adding type-scoped search, be aware the type can contain "/" (is_dir=true)
    const char* pch = key.data();
    const char* start = (const char*)memchr((const void*)pch, '/', key.size());
    return start
      ? string{start, key.size() - static_cast<size_t>(start - pch)}
      : string{};
  };

  leveldb::ReadOptions read_options;
  read_options.snapshot = db->GetSnapshot();
  std::map<string, size_t> resmap; // path => match_count

  typedef std::forward_list<string> PathList;

  PathList master_path_list;
  PathList filename_list;
  auto filename_list_tail = filename_list.before_begin();
  size_t filename_list_count = 0;
  std::set<string> path_set;
  std::set<string> term_uniq_set;
  
  // Do we have any filename matches?
  auto bkp = key(kBasenameKeyPrefix + normalize_term_text(text));
  db_foreach(
    db,
    read_options,
    bkp,
    [&](const leveldb::Slice& key, const leveldb::Slice& value) {
      // Note: assert empty path, or our index building is buggy :-S
      auto path = path_from_index_key(key); assert(!path.empty());
      auto I = path_set.emplace(std::move(path));
      if (I.second) {
        filename_list_tail = filename_list.emplace_after(filename_list_tail, *I.first);
        ++filename_list_count;
      }
      return (filename_list_count < limit * look_ahead_factor); // continue enumeration
    }
  );
  
  u32 term_index = 0;
  // Enumerate terms in reverse order, which will cause any negative terms to be applied last
  for (auto& term : terms) {
    
    // negative term?
    bool term_is_negative = false;
    if (term[0] == '-') {
      term.replace(0, 1, string{});
      term_is_negative = true;
      //std::cout << "NOT term '" << term << "'" << std::endl;
    }
    
    auto kp = key(kNameKeyPrefix + term);

    if (!term_uniq_set.emplace(kp).second) {
      // We already processed this word
      continue;
    }

    // List of unique paths found during this iteration
    PathList path_list;
    size_t path_list_count = 0;
    PathList::iterator path_list_tail = path_list.before_begin();
    
    // Gather all entries which are indexed or prefixed on `term`
    if (term_index == 0) {
      // First word create our initial set
      assert(!term_is_negative); // should never be first and should never be the lone term

      db_foreach(
        db,
        read_options,
        kp,
        [&](const leveldb::Slice& key, const leveldb::Slice& value) {
          // Note: assert empty path, or our index building is buggy :-S
          auto path = path_from_index_key(key); assert(!path.empty());
          auto I = path_set.emplace(std::move(path));
          if (I.second) {
            path_list_tail = path_list.emplace_after(path_list_tail, *I.first);
            ++path_list_count;
          }
          // return: continue enumeration?
          return (path_list_count < limit * (nterms_pos + nterms_neg) * look_ahead_factor);
        }
      );
      
      // Assign path_list to master_path_list
      assert(master_path_list.empty());
      master_path_list.swap(path_list);
      //std::cout << "master_path_list == path_list" << std::endl;
      
      // Put any filename matches at the beginning
      master_path_list.insert_after(
        master_path_list.before_begin(),
        filename_list.begin(),
        filename_list.end()
      );

    } else if (term_is_negative) {
      // Nth term causes our set to shrink by removing any items from master_path_list that matches
      // this term. It's essential a "NOT" logical situation here :-!

      std::set<string> paths_to_remove;
      
      db_foreach(
        db,
        read_options,
        kp,
        [&](const leveldb::Slice& key, const leveldb::Slice& value) {
          auto path = path_from_index_key(key); assert(!path.empty()); // or bug
          if (path_set.find(path) != path_set.end()) {
            // This path is in master_path_list, so let's add it to our set of paths to remove
            paths_to_remove.emplace(std::move(path));
          }
          return true; // continue enumeration
        }
      );
      
      // Remove entries from `master_path_list` which does not exist in `path_list`
      master_path_list.remove_if([&](const string& path){
        if (paths_to_remove.find(path) == paths_to_remove.end()) {
          return false;
        }
        path_set.erase(path);
        return true;
      });

    } else {
      // Nth word causes our set to shrink (or stay unchanged, but never grow)
      // Idea: Could we instead just query the index for prefixes that are part of the set we
      // already have?
      std::set<string> secondary_path_set;
      db_foreach(
        db,
        read_options,
        kp,
        [&](const leveldb::Slice& key, const leveldb::Slice& value) {
          auto path = path_from_index_key(key); assert(!path.empty()); // or bug
          if (path_set.find(path) != path_set.end()) {
            // We have seen this path before, so let's include it unless we already included it for
            // this term.
            auto I = secondary_path_set.emplace(std::move(path));
            if (I.second) {
              path_list_tail = path_list.emplace_after(path_list_tail, *I.first);
              ++path_list_count;
            }
          } // else:
          //     TODO: remove from master_path_list here, saving us the master_path_list.remove_if
          //     loop later. We could do this by changing path_set to be a map, where the value is
          //     the iterator (linked-list link) of the master_path_list entry, and then just
          //     unlinking that entry from master_path_list. We would need to change
          //     master_path_list to be a doubly-linked list (std::list).
          //     If we take this approach, the negative term "subtraction" should be changed in the
          //     same way.
          // return: continue enumeration?
          return (path_list_count < limit * (nterms_pos - term_index) * look_ahead_factor);
        }
      );
      
      //dump_collection("path_list", path_list);
      
      // Remove entries from `master_path_list` which does not exist in `path_list`
      master_path_list.remove_if([&](const string& e1){
        for (auto& e2 : path_list) {
          if (e1 == e2) return false;
        }
        // not found -- remove from path_set and return true to indicate e1 should be removed from
        // maste_path_list
        path_set.erase(e1);
        return true;
      });
    }

    ++term_index;
  }
  
  // populate results ranked on match_count
  // dump_collection("master_path_list", master_path_list);
  Dropbox::SearchResults results;
  u32 master_count = 0;

  for (auto& path : master_path_list) {
    results.emplace_back((size_t)0, (char)0);
    auto st = db->Get(read_options, kFileEntryKeyPrefix + path, &results.back());
    if (!st.ok()) {
      // Report DB lookup error
      std::cout << "[" << __PRETTY_FUNCTION__ << "] index entry pointing to '" << path
                << "' does not have a respective file entry (" << st.ToString() << ")"
                << std::endl;
    }
    if (++master_count == limit) break;
  }

  return std::move(results);
}


} // namespace
