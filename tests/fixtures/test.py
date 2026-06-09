# Test file for pylsp diagnostic picker
import sys

# Unused import (pyflakes)
import os

# PEP 8 violations
def badFunctionName( x,y ):  # pycodestyle: function name, whitespace
    # Line too long (if maxLineLength is set lower)
    really_long_variable_name_that_exceeds_reasonable_line_length_limits = x + y

    # Unused variable (pyflakes)
    unused = 42

    return x+y  # pycodestyle: missing whitespace around operator

class badClassName:  # pycodestyle: class name should be CamelCase
    pass

# Complexity warning (mccabe)
def complex_function(a, b, c, d):
    if a:
        if b:
            if c:
                if d:
                    return a + b + c + d
                else:
                    return a + b + c
            else:
                return a + b
        else:
            return a
    else:
        return 0
