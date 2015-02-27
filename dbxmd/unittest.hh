#pragma once
#include <stdexcept>
#include <iostream>
namespace dbxmd {


#if DEBUG && !defined(DISABLE_UNIT_TESTS)

struct test_failure : std::logic_error {
  test_failure(const string& what) : std::logic_error{what} {}
  test_failure(const char* what) : std::logic_error{what} {}
};


#define UNIT_TEST(name, body) \
  static void test__##name##_main(); \
  __attribute__((constructor)) static void test__##name() { \
    /*std::cerr << ("[test \"" #name "\"] run") << std::endl;*/ \
    try { \
      test__##name##_main(); \
      std::cerr << ("[test] " #name " passed") << std::endl; \
    } catch (const std::exception& e) { \
      std::cerr << ("[test] " #name " failed: ") << e.what() << std::endl; \
      std::rethrow_exception(std::current_exception()); \
    } \
  } \
  static void test__##name##_main() body


#else  /* if !DEBUG || defined(DISABLE_UNIT_TESTS) */

#define UNIT_TEST(name, body)

#endif

} // namespace
