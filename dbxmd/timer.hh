#pragma once
namespace dbxmd {

struct Timer final {
  typedef double Seconds;

  static Timer startTimeout(Seconds, const Thread&, rx::func<void()>);

  Timer(); // == nullptr
  Timer(Seconds delay, Seconds interval, Seconds leeway, const Thread&, rx::func<void(Timer)>);

  const Timer& start() const;
  const Timer& stop() const;

  RX_REF_MIXIN_NOVTABLE(Timer)
};

inline Timer::Timer() : Timer{nullptr} {}

} // namespace
