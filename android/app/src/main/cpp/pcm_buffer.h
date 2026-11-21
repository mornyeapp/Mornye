#pragma once

#include <cstddef>
#include <memory>
#include <new>
#include <utility>

// Sample storage whose growth reports failure. This library builds without
// exceptions, where a std::vector that cannot allocate ends the process.
template <typename T>
class PcmBuffer final {
    std::unique_ptr<T[]> values;
    size_t capacity = 0;
    size_t count = 0;
public:
    // Growing drops the old contents. On false the buffer is unchanged.
    bool resize(size_t size) {
        if (size > capacity) {
            std::unique_ptr<T[]> grown(new (std::nothrow) T[size]());
            if (!grown) return false;
            values = std::move(grown);
            capacity = size;
        }
        count = size;
        return true;
    }
    void clear() { count = 0; }
    size_t size() const { return count; }
    T *data() { return values.get(); }
    const T *data() const { return values.get(); }
    T &operator[](size_t index) { return values[index]; }
    const T &operator[](size_t index) const { return values[index]; }
};
