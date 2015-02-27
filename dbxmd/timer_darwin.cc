#include <rx/rx.h>
#include "thread.hh"
#include "timer.hh"
#include <dispatch/dispatch.h>

namespace dbxmd {

struct Timer::Imp : rx::ref_counted_novtable {
  dispatch_source_t s;
};

void Timer::__dealloc(Timer::Imp* p) { delete p; }

Timer Timer::startTimeout(Seconds delay, const Thread& t, rx::func<void()> cb) {
  Timer timer{delay, 0, -1, t, [cb](Timer t){ cb(); }};
  timer.start();
  return std::move(timer);
}

Timer::Timer(
  Seconds delay,
  Seconds interval,
  Seconds leeway,
  const Thread& t,
  rx::func<void(Timer)> cb) : self{new Imp}
{
  auto mksectime = [](Seconds s) {
    return dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * 1000000000.0));
  };
  auto delayns    = mksectime(delay);
  auto intervalns = interval <= 0 ? DISPATCH_TIME_FOREVER : mksectime(interval);
  auto leewayns   = mksectime(leeway < 0 ? (RX_MAX(delay, interval) / 4) : leeway);

  assert(t.type() == Thread::Type::DispatchQueue);
  dispatch_queue_t q = (dispatch_queue_t)t.ptr();

  self->s = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  dispatch_source_set_event_handler(self->s, ^{ cb(*this); });
  dispatch_source_set_timer(self->s, delayns, intervalns, leewayns);
}

const Timer& Timer::start() const {
  dispatch_resume(self->s);
  return *this;
}

const Timer& Timer::stop() const {
  dispatch_suspend(self->s);
  return *this;
}


} // namespace
