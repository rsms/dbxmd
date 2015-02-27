#pragma once
namespace dbxmd {

struct Thread final {
  enum class Type {
    DispatchQueue,  // Apple libdispatch dispatch_queue
  };
  Thread(); // == nullptr
  Thread(void* p, Type);

  static const Thread& main();

  Type type() const;
  void* ptr() const;

  void async(rx::func<void()>) const;

  RX_REF_MIXIN_NOVTABLE(Thread)
};


inline Thread::Thread() : Thread{nullptr} {}

} // namespace
