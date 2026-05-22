// Test file for clangd diagnostic picker
#include <iostream>
#include <vector>

// This should trigger various warnings based on enabled checks
int main() {
    // Magic number (readability-magic-numbers)
    int x = 42;

    // Old-style for loop (modernize-loop-convert)
    std::vector<int> vec = {1, 2, 3, 4, 5};
    for (int i = 0; i < vec.size(); ++i) {
        std::cout << vec[i] << std::endl;
    }

    // C-style cast (cppcoreguidelines-pro-type-cstyle-cast)
    double pi = 3.14;
    int rounded = (int)pi;

    // Unused variable (clang-diagnostic-unused-variable)
    int unused = 100;

    // Implicit conversion (bugprone-narrowing-conversions)
    long long big = 1000000000000LL;
    int small = big;

    return 0;
}
