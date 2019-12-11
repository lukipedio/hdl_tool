"""
========================================================
    Filename: lexer.py
    Author: Marius Elvegård
    Description:

    (c) 2019 Marius Elvegård
========================================================
"""


import re


_keywords = ["abs", "file", "access", "for", "after", "function", "alias", "all", "generate", "and", "generic", "architecture", "guarded", "array", 
            "assert", "if", "attribute", "impure", "in", "begin", "inertial", "block", "inout", "body", "is", "buffer", "bus", "label", "library",
            "case", "linkage", "component", "literal", "configuration", "loop", "of", "on", "open", "or", "others", "out", "package", "port", "postponed", 
            "procedure", "process", "pure", "range", "record", "register", "reject", "rem", "report", "return", "rol", "ror", "select", "severity", "shared",
            "signal", "sla", "sll", "sra", "srl", "subtype", "then", "to", "transport", "type", "unaffected", "units", "until", "use", "variable", "wait",
            "when", "while", "with", "xnor", "xor", "constant", "disconnect", "mod", "downto", "nand", "else", "new", "elsif", "next", "end", "nor", 
            "entity", "not", "exit", "null", "context"]

_commons = ["rising_edge", "falling_edge"]

_comments = ["--"]

_assignment = ["=>", "<=", ":="]

_operator = ["=/*=-+"]

_symbols = ["(", ")", "[", "]", ";", ",", ".", "\""]
_string = ["\""]

_new_line = ["\n"]



class Lexer(object):


    def __init__(self, source_code):
        # File to tokenize
        self.source_code = source_code


    def _complete_string(self, str):
        is_complete = True
        for c in str:
            if c == "\"":
                is_complete = not(is_complete)
        return is_complete


    def tokenize(self):
        # Container
        tokens = []

        # Creating word list of source code
        source_code = re.findall(r'\S+|\n', self.source_code)

        # Word index counter
        source_index = 0

        # Set to True when parsing inside a string
        in_string = False

        # Loop words in source code and generate tokens
        while source_index < len(source_code):
            word = source_code[source_index]

            # Check for statement endings and remove from word if found. Will be added as a keyword after.
            statement_end = False
            if word[len(word)-1] in _symbols:
                word = word[:len(word)-1]
                statement_end = True

            # Detect if this is a code comment
            if word[0:2] == "--":
                while word[len(word)-1] != "\n":
                    source_index += 1
                    word += source_code[source_index]   
                tokens.append(["COMMENT", word])

            # Detect if this is a string
            elif "\"" in word:
                source_index += 1

                # Complete string
                if word.count("\"") == 2:
                    tokens.append(["STRING", word])
                    continue    
                # Incomplete string
                else:
                    text_string = word
                    # Keep on reading until string is complete
                    for idx in range(source_index, len(source_code)-1):
                        text_string += source_code[idx]
                        if "\"" in source_code[idx]:
                            source_index = idx + 1
                            tokens.append(["STRING", text_string])
                            continue
    


            else:
                if word.lower() in _keywords:
                    tokens.append(["KEYWORD", word])

                elif word.lower() in _commons:
                    tokens.append(["COMMON_KEYWORD", word])

                elif word in _assignment:
                    tokens.append(["ASSIGNMENT", word])

                elif word in _operator:
                    tokens.append(["OPERATOR", word])

                elif word in _symbols:
                    tokens.append(["SYMBOL", word])

                elif re.match('[0-9]', word): 
                    tokens.append(["INTEGER", word])

                elif re.match('[a-z]', word.lower()):
                    tokens.append(["IDENTIFIER", word])

                elif word in _comments:
                    tokens.append(["COMMENT", word])

                elif word in _new_line:
                    tokens.append(["NEW_LINE", "\n"])

                else:
                    tokens.append(["UNKNOWN", word])

                if statement_end:
                    tokens.append(["STATEMENT_END", ";"])


                # Increment word index counter
                source_index += 1

        return tokens
