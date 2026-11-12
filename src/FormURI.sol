// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev RFC 3986 URI characters only. No whitespace, quotes, backslashes or non-ASCII text.
/// The URI remains untrusted data even when it passes this syntactic check.
library FormURI {
    function valid(string memory uri) internal pure returns (bool) {
        bytes memory u = bytes(uri);
        if (u.length == 0 || u.length > 200) return false;
        for (uint256 i; i < u.length; ++i) {
            bytes1 c = u[i];
            if (
                (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "."
                    || c == "_" || c == "~" || c == ":" || c == "/" || c == "?" || c == "#" || c == "[" || c == "]"
                    || c == "@" || c == "!" || c == "$" || c == "&" || c == "'" || c == "(" || c == ")" || c == "*"
                    || c == "+" || c == "," || c == ";" || c == "=" || c == "%"
            ) continue;
            return false;
        }
        return true;
    }
}
