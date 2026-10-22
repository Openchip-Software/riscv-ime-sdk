// SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
// SPDX-License-Identifier: Apache-2.0
#include <iostream>
#include <string>
#include <vector>

int main()
{
    std::vector<std::string> words{"hello", "from", "C++"};
    std::string line;
    for (const auto &w : words)
        line += (line.empty() ? "" : " ") + w;
    std::cout << line << std::endl;
    return 0;
}
