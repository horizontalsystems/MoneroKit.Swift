#ifndef ZANO_HELPERS_HPP
#define ZANO_HELPERS_HPP

#include <cstdlib>
#include <iostream>

// Debug macros for exception handling in C API functions
#define DEBUG_START()                                                             \
    try {

#define DEBUG_END()                                                               \
    } catch (const std::exception &e) {                                           \
        std::cerr << "Exception caught in function: " << __FUNCTION__             \
                  << " at " << __FILE__ << ":" << __LINE__ << std::endl           \
                  << "Message: " << e.what() << std::endl;                        \
        std::abort();                                                             \
    } catch (...) {                                                               \
        std::cerr << "Unknown exception caught in function: " << __FUNCTION__     \
                  << " at " << __FILE__ << ":" << __LINE__ << std::endl;          \
        std::abort();                                                             \
    }

// Note: Helper functions (vectorToString, splitString, etc.) were removed
// as they are not used by Zano's plain_wallet API and caused duplicate
// symbol conflicts when linking with MoneroKit.

#endif // ZANO_HELPERS_HPP
