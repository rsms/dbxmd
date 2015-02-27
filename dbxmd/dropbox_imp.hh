#pragma once
#include "thread.hh"
#include "timer.hh"
#include "netreach.hh"
#include "doc.hh"
#include <rx/status.hh>
#include <rx/state.hh>
#include <json11/json11.hh>
#include <leveldb/db.h>
#include <leveldb/write_batch.h>
#include <vector>
#include <list>
// #include <thread>
#include <mutex>
namespace dbxmd {

using rx::Status;
using json11::Json;


struct Dropbox::Imp : rx::ref_counted_novtable {
  std::string         uid;
  std::string         access_token;
  std::string         path_prefix;
  AuthExpiredCallback auth_expired_cb;

  leveldb::DB*        db = nullptr;
  leveldb::Options    db_options;

  Thread              thread;
  NetReach            dbx_api_reachability;
  bool                delta_has_more = true;
  bool                dbx_api_is_reachable = false;
  rx::func<void()>    once_dbx_api_became_reachable;
  Status              last_api_status;
  double              api_back_off_time = 0; // seconds

  rx::State<std::string> state;

  void delta_get(rx::func<void(Status)>);
  void delta_wait(rx::func<void(Status)>);
  void reset_delta_cursor();
  Status apply_dbx_delta(const Json& delta, leveldb::DB*);

  void apply_doc_entries(const DocEntries&, leveldb::DB*, leveldb::WriteBatch&);

  void check_dbversion();
  void start();
  void reauthenticate();
  void inc_api_back_off_time(double seconds_min, double seconds_max);

  // change observation
  using DataChangeListeners = std::map<string, std::list<DataChangeListener>>;
  DataChangeListeners data_change_listeners;
  std::mutex          data_change_listeners_mu;
  // TODO: remove_change_listener()
  void notify_data_changes(const leveldb::WriteBatch&);

  Imp(
    const std::string& uid,
    const std::string& access_token,
    const std::string& path_prefix,
    AuthExpiredCallback auth_expired_cb);
  ~Imp();
};

} // namespace
