#include <rx/rx.h>
#include "thread.hh"
#include <dispatch/dispatch.h>
#include <exception>
#include <iostream>
#include <execinfo.h>

namespace dbxmd {


//static void PrintStackTrace(FILE *out) {
//  // storage array for stack trace address data
//  void* addrlist[/*nframes=*/100 + 1];
//
//  // retrieve current stack addresses
//  u32 addrlen = backtrace(addrlist, sizeof(addrlist) / sizeof(void*));
//
//  if (addrlen == 0) {
//    fprintf(out, "  \n");
//    return;
//  }
//
//  // create readable strings to each frame.
//  char** symbollist = backtrace_symbols( addrlist, addrlen );
//
//  // print the stack trace.
//  for (size_t i = 4; i < addrlen; i++) {
//    fprintf(out, "%s\n", symbollist[i]);
//  }
//
//  free(symbollist);
//}


struct Thread::Imp : rx::ref_counted_novtable {
  dispatch_queue_t dispatch_queue;
  Imp(void* p) : dispatch_queue{(dispatch_queue_t)p} {
    if (dispatch_queue != nullptr) {
      dispatch_retain(dispatch_queue);
    }
  }
  ~Imp() {
    if (dispatch_queue != nullptr) {
      dispatch_release(dispatch_queue);
    }
  }
};

void Thread::__dealloc(Thread::Imp* p) { delete p; }

Thread::Thread(void* p, Type t) : self{new Imp{p}} {
  assert(t == Type::DispatchQueue);
}

const Thread& Thread::main() {
  static Thread t;
  static dispatch_once_t onceToken; dispatch_once(&onceToken, ^{
    t.self = new Thread::Imp{dispatch_get_main_queue()};
  });
  return t;
}

Thread::Type Thread::type() const {
  return Type::DispatchQueue;
}

void* Thread::ptr() const {
  return (void*)self->dispatch_queue;
}

void Thread::async(rx::func<void()> fn) const {
  assert(self != nullptr);
  assert(self->dispatch_queue != nullptr);
  dispatch_async(self->dispatch_queue, ^{
    fn();
  });
}

} // namespace
