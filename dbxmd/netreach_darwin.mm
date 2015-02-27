#import <rx/rx.h>
#import "thread.hh"
#import "netreach.hh"
#import <string>
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <iostream>

using std::cerr;
using std::endl;

namespace dbxmd {


static NetReach::State StateForFlags(SCNetworkConnectionFlags flags) {
  if ((flags & kSCNetworkFlagsReachable) && !(flags & kSCNetworkFlagsConnectionRequired)) {
    return NetReach::State::Reachable;
  } else {
    return NetReach::State::Unreachable;
  }
}


#if 1
#define DBG_DumpFlags(...) do{}while(0)
#else
static const char* StateName(NetReach::State state) {
  switch (state) {
    case NetReach::State::Reachable:   return "Reachable";
    case NetReach::State::Unreachable: return "Unreachable";
  }
}

static void DBG_DumpFlags(SCNetworkConnectionFlags flags) {
  cerr << "netreach flags changed:" << endl;
  if (flags & kSCNetworkReachabilityFlagsTransientConnection) {
    cerr << "  TransientConnection" << endl; }
  if (flags & kSCNetworkReachabilityFlagsReachable) {
    cerr << "  Reachable" << endl; }
  if (flags & kSCNetworkReachabilityFlagsConnectionRequired) {
    cerr << "  ConnectionRequired" << endl; }
  if (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) {
    cerr << "  ConnectionOnTraffic" << endl; }
  if (flags & kSCNetworkReachabilityFlagsInterventionRequired) {
    cerr << "  InterventionRequired" << endl; }
  if (flags & kSCNetworkReachabilityFlagsConnectionOnDemand) {
    cerr << "  ConnectionOnDemand" << endl; }
  if (flags & kSCNetworkReachabilityFlagsIsLocalAddress) {
    cerr << "  IsLocalAddress" << endl; }
  if (flags & kSCNetworkReachabilityFlagsIsDirect) {
    cerr << "  IsDirect" << endl; }
  #if RX_TARGET_OS_IOS
  if (flags & kSCNetworkReachabilityFlagsIsWWAN) {
    cerr << "  IsWWAN" << endl; }
  #endif
  cerr << "NetReach::State = " << StateName(StateForFlags(flags)) << endl;
}
#endif


struct NetReach::Imp : rx::ref_counted_novtable {
  Callback                 cb;
  volatile State           state;
  SCNetworkReachabilityRef r = nullptr;

  Imp(State initialState, Callback cb) : state{initialState}, cb{cb} {}

  ~Imp() {
    if (r != NULL) {
      SCNetworkReachabilitySetDispatchQueue(r, NULL);
      CFRelease(r);
    }
  }

  void setState(State s) {
    if (state != s) {
      state = s;
      if (cb != nullptr) cb(s);
    }
  }

  static void SCNetworkCallback(
     SCNetworkReachabilityRef target,
     SCNetworkConnectionFlags flags,
     void* self)
  {
    // Observed flags:
    // - nearly gone: kSCNetworkFlagsReachable alone (ignored)
    // - gone: kSCNetworkFlagsTransientConnection | kSCNetworkFlagsReachable | kSCNetworkFlagsConnectionRequired
    // - connected: kSCNetworkFlagsIsDirect | kSCNetworkFlagsReachable
    DBG_DumpFlags(flags);
    ((Imp*)self)->setState(StateForFlags(flags));
  }

};

void NetReach::__dealloc(NetReach::Imp* p) { delete p; }


NetReach::State NetReach::state() const {
  return (self == nullptr) ? State::Unreachable : self->state;
}


NetReach::NetReach(const std::string& hostname, State initialState, Callback cb)
  : self{new Imp{initialState, cb}}
{
  // Setup dbx API endpoint network reachability observer
  // TODO: modularize
  self->r = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, hostname.c_str());
  assert(self->r != NULL); // FIXME, TODO: error-check the things below here
  SCNetworkReachabilityContext context = {0, (void*)self, NULL, NULL, NULL};
  SCNetworkReachabilitySetCallback(self->r, NetReach::Imp::SCNetworkCallback, &context);
}


void NetReach::resume() {
  SCNetworkReachabilitySetDispatchQueue(self->r, dispatch_get_main_queue());
  auto bgqueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  auto s = *this;
  dispatch_async(bgqueue, ^{
    SCNetworkConnectionFlags flags;
    if (SCNetworkReachabilityGetFlags(s.self->r, &flags)) {
      dispatch_async(dispatch_get_main_queue(), ^{
        s.self->setState(StateForFlags(flags));
      });
    }
  });
}


void NetReach::suspend() {
  if (self != nullptr) {
    SCNetworkReachabilitySetDispatchQueue(self->r, NULL);
  }
}

} // namespace
