// Copyright (C) MrCyjaneK and monero_c contributors
// https://github.com/MrCyjaneK/monero_c
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with this library. If not, see <https://www.gnu.org/licenses/>.

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
