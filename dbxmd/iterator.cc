#include <rx/rx.h>
#include <leveldb/db.h>
#include "dbxmd.h"
#include "iterator_imp.hh"
#include "keyspace.hh"
#include <iostream>
namespace dbxmd {

void Iterator::__dealloc(Iterator::Imp* p) { delete p; }


void Iterator::seekToFirst() {
  if (self != nullptr) {
    self->it->Seek(self->key_prefix);
  }
}

void Iterator::seekToLast() {
  if (self != nullptr) {
    self->it->Seek(self->key_prefix_terminal_slice);
    if (self->it->Valid()) {
//      std::clog << "Iterator::seekToLast: '" << self->key_prefix_terminal_slice.ToString()
//                << "' key='" << self->it->key().ToString() << "'" << std::endl;
//      valid();
      self->it->Prev();
//      if (!self->it->Valid() || !self->it->key().starts_with(self->key_prefix)) {
//        self->it->Next();
//      }
//      if (self->it->Valid()) {
//        std::clog << "Iterator::seekToLast: Prev(): key='" << self->it->key().ToString()
//                  << "'" << std::endl;
//      }
//    } else {
//      std::clog << "Iterator::seekToLast: '" << self->key_prefix_terminal_slice.ToString()
//                << "' FAIL" << std::endl;
    }
  }
}

void Iterator::seekToKey(const string& key) {
  if (self != nullptr) {
    self->it->Seek(self->key_prefix + key);
//    if (!self->it->Valid() || !self->it->key().starts_with(self->key_prefix)) {
//      
//    }
  }
}

bool Iterator::valid() const {
//  std::clog << "Iterator::valid:\n"
//            << "  it->Valid() => " << self->it->Valid() << " &&\n"
//            << "  (key=\"" << self->it->key().ToString() << "\").compare() = "
//              << "(key_prefix_terminal_slice=\"" << self->key_prefix_terminal_slice.ToString()
//              << "\") => " << self->it->key().compare(self->key_prefix_terminal_slice) << "\n"
//            << "  (it->key().ToString()=\"" << self->it->key().ToString() << "\") "
//              << "< (key_prefix_terminal=\"" << self->key_prefix_terminal << "\") => "
//              << (self->it->key().ToString() < self->key_prefix_terminal)
//            << std::endl;
  return
    self != nullptr &&
    self->it->Valid() &&
    self->it->key().starts_with(self->key_prefix) &&
    self->it->key().compare(self->key_prefix_terminal_slice) < 0;
//    self->it->key().ToString() < self->key_prefix_terminal;
    //self->it->key().starts_with(self->key_prefix) &&
    //self->it->key().compare(self->key_prefix_terminal_slice) < 0;

  // if (self != nullptr && self->it->Valid()) {
  //   auto k = self->it->key();
  //   if (k.starts_with(self->key_prefix)) {
  //     std::clog << k.ToString() << " = " << k.compare(self->key_prefix_terminal_slice) << std::endl;
  //     return true;
  //   }
  // }
  // return false;
}

string Iterator::key() const {
  auto s = self->it->key();
  s.remove_prefix(self->key_prefix.size());
  return s.ToString();
}

string Iterator::entryValue() const {
  string v;
  self->db->Get(self->read_options, kFileEntryKeyPrefix + value(), &v);
  return v;
}

string Iterator::value() const {
  return self->it->value().ToString();
}

const char* Iterator::dataValue(size_t& size) const {
  auto s = self->it->value();
  size = s.size();
  return s.data();
}

void Iterator::next() {
  self->it->Next();
}

void Iterator::prev() {
  self->it->Prev();
}


} // namespace
