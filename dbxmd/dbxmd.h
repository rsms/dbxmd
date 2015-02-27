#pragma once
#ifdef __cplusplus

#include <rx/rx.h>
#include <rx/status.hh>
#include <leveldb/slice.h>
#include <string>
#include <vector>

namespace dbxmd {
using std::string;
using rx::Status;
struct Iterator;


// Data change description
struct DataChange {
  enum Kind { Modified, Removed };
  leveldb::Slice key;
  Kind           kind;
  DataChange(const leveldb::Slice& key, Kind kind) : key{key}, kind{kind} {}
  DataChange(const DataChange&) = delete;
  DataChange(DataChange&&) = default;
};
using DataChanges = std::vector<DataChange>;
using DataChangeListener = rx::func<void(const DataChanges&)>;
using ListenerID = intptr_t;

using ReauthenticateCallback = rx::func<void(const string& access_token)>;

// Called when the access_token is reported invalid.
// Should call ReauthenticateCallback with a new valid access_token, or
// call it with an empty string to end server communication after which
// point the invoking Dropbox object will no longer update.
using AuthExpiredCallback = rx::func<void(ReauthenticateCallback)>;


// Represents a read-only view of a specific account's Dropbox
struct Dropbox {

  // Initialize a new object with an oauth2 access token
  Dropbox(
    const string& uid,
    const string& access_token,
    const string& path_prefix,
    AuthExpiredCallback
  );

  // Empty (==nullptr)
  Dropbox();

  // Open the underlying storage and establish network connections, etc.
  // This call blocks while opening the database and verifying its version, but beyond
  // that all calls (networking, index updating, etc) happens in a background thread.
  // data_dirname is the file-system directory where the database will be stored.
  // The actual path of the database is a subdirectory within data_dirname which
  // contains the uid. I.e. different uids do not collide or share data.
  // The directory will be automatically created if it does not yet exist.
  Status open(const string& data_dirname);

  // UID passed to the constructor
  const string& uid() const;

  // access token
  const string& access_token() const;

  // Set the access_token. Useful after reauthentication.
  void set_access_token(const string&);

  // Search results. Each value is a JSON-encoded represenation of an entry.
  typedef std::vector<string> SearchResults;

  // Query the index for things matching `text` or optional `type`, returning up to `limit` results
  // starting from `offset` result. To return all matches, pass 0 for both offset and limit.
  SearchResults search(const string& type, const string& text, u32 limit) const;
  const string& searchDataKey() const;

  // List recently edited files (by the uid provided to the constructor)
  Iterator newRecentsIterator() const;
  const string& recentsDataKey() const;

  // Register for data changes to key prefix
  ListenerID addChangeListener(const string& keyPrefix, DataChangeListener);
  void removeChangeListener(const string& keyPrefix, ListenerID);

  RX_REF_MIXIN_NOVTABLE(Dropbox)
};


// Allows iterating over a series of key-value entries
struct Iterator {
  // an empty iterator
  Iterator();

  void seekToFirst();
  void seekToLast();
  void seekToKey(const string&);
  bool valid() const;
  string key() const;

  // The current value
  string value() const;

  // Reference to underlying bytes. Returned pointer is valid until calling next() or prev().
  const char* dataValue(size_t& size) const;

  // Assuming the current value points to a file entry key, this method returns that file entry
  // as it was at the point in time when the iterator was created. The returned string is a
  // JSON-encoded represenation of an entry.
  string entryValue() const;

  void next();
  void prev();

  RX_REF_MIXIN_NOVTABLE(Iterator)
};


// --------------------------------------------------------------------------------------

inline Dropbox::Dropbox() : Dropbox(nullptr) {}
inline Iterator::Iterator() : Iterator{nullptr} {}

} // namespace

#endif /* defined(__cplusplus) */
