// Independent scalar oracle using TensorFlow's bundled upstream gemmlowp.
#include <algorithm>
#include <cstdint>
#include <iostream>
#include "fixedpoint/fixedpoint.h"
int main() {
    int64_t sum, bias, multiplier, shift, zero, low, high;
    while (std::cin >> sum >> bias >> multiplier >> shift >> zero >> low >> high) {
        int64_t biased = sum + bias;
        bool fault = biased < INT32_MIN || biased > INT32_MAX || multiplier <= 0 ||
                     multiplier > INT32_MAX || low > high || shift < 0 || shift > 31;
        int64_t value = 0;
        if (!fault) {
            int32_t scaled = gemmlowp::SaturatingRoundingDoublingHighMul(
                static_cast<int32_t>(biased), static_cast<int32_t>(multiplier));
            value = gemmlowp::RoundingDivideByPOT(scaled, static_cast<int>(shift));
            value = std::min(high, std::max(low, value + zero));
        }
        std::cout << value << ' ' << fault << '\n';
    }
}
