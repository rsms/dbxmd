#pragma once
#include <rx/rx.h>

namespace dbxmd {

struct NetReach final {
  enum class State {
    Unreachable,
    Reachable,
  };
  using Callback = rx::func<void(State)>; // argument is true when reachable

  NetReach(const std::string& hostname, State initialState, Callback);

  State state() const;
  bool isReachable() const;

  void resume();
  void suspend();

  RX_REF_MIXIN_NOVTABLE(NetReach)
};


inline bool NetReach::isReachable() const { return state() == NetReach::State::Reachable; }


} // namespace
