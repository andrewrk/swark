# The Lexer. Uses a series of token-matching regexes to attempt
# matches against the beginning of the source code. When a match is found,
# a token is produced, we consume the match, and start again. Tokens are in the
# form:
#
#     [tag, value, lineNumber]
#
# Which is a format that can be fed directly into [Jison](http://github.com/zaach/jison).

{Rewriter, INVERSES} = require './rewriter'

# Gets the last item of an array(-like) object.
last = (array, back) -> array[array.length - (back or 0) - 1]

# Count the number of occurrences of a string in a string.
count = (string, substr) ->
  num = pos = 0
  return 1/0 unless substr.length
  num++ while pos = 1 + string.indexOf substr, pos
  num

# The Lexer Class
# ---------------

# The Lexer class reads a stream of code and divvies it up into tagged
# tokens. Some potential ambiguity in the grammar has been avoided by
# pushing some extra smarts into the Lexer.
exports.Lexer = class Lexer

  # **tokenize** is the Lexer's main method. Scan by attempting to match tokens
  # one at a time, using a regular expression anchored at the start of the
  # remaining code, or a custom recursive token-matching method
  # (for interpolations). When the next token has been recorded, we move forward
  # within the code past the token, and begin again.
  #
  # Each tokenizing method is responsible for returning the number of characters
  # it has consumed.
  #
  # Before returning the token stream, run it through the [Rewriter](rewriter.html)
  # unless explicitly asked not to.
  tokenize: (code, opts = {}) ->
    code     = "\n#{code}" if WHITESPACE.test code
    code     = code.replace TRAILING_SPACES, ''

    @code    = code           # The remainder of the source code.
    @line    = opts.line or 0 # The current line.
    @indent  = 0              # The current indentation level.
    @indebt  = 0              # The over-indentation at the current level.
    @outdebt = 0              # The under-outdentation at the current level.
    @indents = []             # The stack of all current indentation levels.
    @ends    = []             # The stack for pairing up tokens.
    @tokens  = []             # Stream of parsed tokens in the form `['TYPE', value, line]`.

    # At every position, run through this list of attempted matches,
    # short-circuiting if any of them succeed. Their order determines precedence:
    # `@literalToken` is the fallback catch-all.
    i = 0
    while @chunk = code[i..]
      i += @invalidToken()    or
           @identifierToken() or
           @commentToken()    or
           @whitespaceToken() or
           @lineToken()       or
           @heredocToken()    or
           @stringToken()     or
           @numberToken()     or
           @literalToken()

    @closeIndentation()
    @error "missing #{tag}" if tag = @ends.pop()
    return @tokens if opts.rewrite is off
    (new Rewriter).rewrite @tokens

  # Tokenizers
  # ----------
  invalidToken: ->
    c = @chunk[0]
    if c in "\t\r"
      @error "#{JSON.stringify(c)} is not a valid character"
    return 0

  # Matches identifying literals: variables, keywords, method names, etc.
  # Check to ensure that JavaScript reserved words aren't being used as
  # identifiers. Because we reserve a handful of keywords that are
  # allowed in JavaScript, we're careful not to tag them as keywords when
  # referenced as property names here, so you can still do `jQuery.is()` even
  # though `is` means `===` otherwise.
  identifierToken: ->
    return 0 unless match = IDENTIFIER.exec @chunk
    [input, id, colon] = match

    if id is 'own' and @tag() is 'FOR'
      @token 'OWN', id
      return id.length
    forcedIdentifier = colon or
      (prev = last @tokens) and (prev[0] in ['.', '::'] or
      not prev.spaced and prev[0] is '@')
    tag = 'IDENTIFIER'

    if not forcedIdentifier and (id in RESERVED)
      tag = id.toUpperCase()
      if tag is 'WHEN' and @tag() in LINE_BREAK
        tag = 'LEADING_WHEN'
      else if tag is 'FOR'
        @seenFor = yes
      else if tag is 'UNLESS'
        tag = 'IF'
      else if tag in UNARY
        tag = 'UNARY'
      else if tag in RELATION
        if tag isnt 'INSTANCEOF' and @seenFor
          tag = 'FOR' + tag
          @seenFor = no
        else
          tag = 'RELATION'
          if @value() is '!'
            @tokens.pop()
            id = '!' + id

    if forcedIdentifier
      tag = 'IDENTIFIER'
      id  = new String id
      id.reserved = yes

    unless forcedIdentifier
      tag = switch id
        when '!'                                  then 'UNARY'
        when '==', '!='                           then 'COMPARE'
        when '&&', '||'                           then 'LOGIC'
        when 'true', 'false'                      then 'BOOL'
        when 'break', 'continue'                  then 'STATEMENT'
        else  tag

    @token tag, id
    @token ':', ':' if colon
    input.length

  # Matches numbers, including decimals, hex, and exponential notation.
  # Be careful not to interfere with ranges-in-progress.
  numberToken: ->
    return 0 unless match = NUMBER.exec @chunk
    number = match[0]
    if /^0[BOX]/.test number
      @error "radix prefix '#{number}' must be lowercase"
    else if /E/.test(number) and not /^0x/.test number
      @error "exponential notation '#{number}' must be indicated with a lowercase 'e'"
    else if /^0\d*[89]/.test number
      @error "decimal literal '#{number}' must not be prefixed with '0'"
    else if /^0\d+/.test number
      @error "octal literal '#{number}' must be prefixed with '0o'"
    lexedLength = number.length
    if octalLiteral = /^0o([0-7]+)/.exec number
      number = '0x' + (parseInt octalLiteral[1], 8).toString 16
    if binaryLiteral = /^0b([01]+)/.exec number
      number = '0x' + (parseInt binaryLiteral[1], 2).toString 16
    @token 'NUMBER', number
    lexedLength

  # Matches strings, including multi-line strings. Ensures that quotation marks
  # are balanced within the string's contents, and within nested interpolations.
  stringToken: ->
    switch @chunk.charAt 0
      when "'"
        return 0 unless match = SIMPLESTR.exec @chunk
        @token 'STRING', (string = match[0]).replace MULTILINER, '\\\n'
      when '"'
        return 0 unless string = @balancedString @chunk, '"'
        if 0 < string.indexOf '#{', 1
          @interpolateString string[1...-1]
        else
          @token 'STRING', @escapeLines string
      else
        return 0
    if octalEsc = /^(?:\\.|[^\\])*\\[0-7]/.test string
      @error "octal escape sequences #{string} are not allowed"
    @line += count string, '\n'
    string.length

  # Matches heredocs, adjusting indentation to the correct level, as heredocs
  # preserve whitespace, but ignore indentation to the left.
  heredocToken: ->
    return 0 unless match = HEREDOC.exec @chunk
    heredoc = match[0]
    quote = heredoc.charAt 0
    doc = @sanitizeHeredoc match[2], quote: quote, indent: null
    if quote is '"' and 0 <= doc.indexOf '#{'
      @interpolateString doc, heredoc: yes
    else
      @token 'STRING', @makeString doc, quote, yes
    @line += count heredoc, '\n'
    heredoc.length

  # Matches and consumes comments.
  commentToken: ->
    return 0 unless match = @chunk.match COMMENT
    [comment, here] = match
    if here
      @token 'HERECOMMENT', @sanitizeHeredoc here,
        herecomment: true, indent: Array(@indent + 1).join(' ')
    @line += count comment, '\n'
    comment.length

  # Matches newlines, indents, and outdents, and determines which is which.
  # If we can detect that the current line is continued onto the the next line,
  # then the newline is suppressed:
  #
  #     elements
  #       .each( ... )
  #       .map( ... )
  #
  # Keeps track of the level of indentation, because a single outdent token
  # can close multiple indents, so we need to know how far in we happen to be.
  lineToken: ->
    return 0 unless match = MULTI_DENT.exec @chunk
    indent = match[0]
    @line += count indent, '\n'
    @seenFor = no
    prev = last @tokens, 1
    size = indent.length - 1 - indent.lastIndexOf '\n'
    noNewlines = @unfinished()
    if size - @indebt is @indent
      if noNewlines then @suppressNewlines() else @newlineToken()
      return indent.length
    if size > @indent
      if noNewlines
        @indebt = size - @indent
        @suppressNewlines()
        return indent.length
      diff = size - @indent + @outdebt
      @token 'INDENT', diff
      @indents.push diff
      @ends.push 'OUTDENT'
      @outdebt = @indebt = 0
    else
      @indebt = 0
      @outdentToken @indent - size, noNewlines
    @indent = size
    indent.length

  # Record an outdent token or multiple tokens, if we happen to be moving back
  # inwards past several recorded indents.
  outdentToken: (moveOut, noNewlines) ->
    while moveOut > 0
      len = @indents.length - 1
      if @indents[len] is undefined
        moveOut = 0
      else if @indents[len] is @outdebt
        moveOut -= @outdebt
        @outdebt = 0
      else if @indents[len] < @outdebt
        @outdebt -= @indents[len]
        moveOut  -= @indents[len]
      else
        dent = @indents.pop() - @outdebt
        moveOut -= dent
        @outdebt = 0
        @pair 'OUTDENT'
        @token 'OUTDENT', dent
    @outdebt -= moveOut if dent
    @tokens.pop() while @value() is ';'
    @token 'TERMINATOR', '\n' unless @tag() is 'TERMINATOR' or noNewlines
    this

  # Matches and consumes non-meaningful whitespace. Tag the previous token
  # as being "spaced", because there are some cases where it makes a difference.
  whitespaceToken: ->
    return 0 unless (match = WHITESPACE.exec @chunk) or
                    (nline = @chunk.charAt(0) is '\n')
    prev = last @tokens
    prev[if match then 'spaced' else 'newLine'] = true if prev
    if match then match[0].length else 0

  # Generate a newline token. Consecutive newlines get merged together.
  newlineToken: ->
    @tokens.pop() while @value() is ';'
    @token 'TERMINATOR', '\n' unless @tag() is 'TERMINATOR'
    this

  # Use a `\` at a line-ending to suppress the newline.
  # The slash is removed here once its job is done.
  suppressNewlines: ->
    @tokens.pop() if @value() is '\\'
    this

  # We treat all other single characters as a token. E.g.: `( ) , . !`
  # Multi-character operators are also literal tokens, so that Jison can assign
  # the proper order of operations. There are some symbols that we tag specially
  # here. `;` and newlines are both treated as a `TERMINATOR`, we distinguish
  # parentheses that indicate a method call from regular parentheses, and so on.
  literalToken: ->
    if match = OPERATOR.exec @chunk
      [value] = match
      @tagParameters() if CODE.test value
    else
      value = @chunk.charAt 0
    tag  = value
    prev = last @tokens
    if value is '=' and prev
      if prev[1] in ['||', '&&']
        prev[0] = 'COMPOUND_ASSIGN'
        prev[1] += '='
        return value.length
    if value is ';'
      @seenFor = no
      tag = 'TERMINATOR'
    else if value in MATH            then tag = 'MATH'
    else if value in COMPARE         then tag = 'COMPARE'
    else if value in ASSIGN          then tag = 'ASSIGN'
    else if value in COMPOUND_ASSIGN then tag = 'COMPOUND_ASSIGN'
    else if value in UNARY           then tag = 'UNARY'
    else if value in SHIFT           then tag = 'SHIFT'
    else if value in LOGIC           then tag = 'LOGIC'
    else if prev and not prev.spaced
      if value is '(' and prev[0] in CALLABLE
        tag = 'CALL_START'
      else if value is '[' and prev[0] in INDEXABLE
        tag = 'INDEX_START'
    switch value
      when '(', '{', '[' then @ends.push INVERSES[value]
      when ')', '}', ']' then @pair value
    @token tag, value
    value.length

  # Token Manipulators
  # ------------------

  # Sanitize a heredoc or herecomment by
  # erasing all external indentation on the left-hand side.
  sanitizeHeredoc: (doc, options) ->
    {indent, herecomment} = options
    if herecomment
      if HEREDOC_ILLEGAL.test doc
        @error "block comment cannot contain \"*/\", starting"
      return doc if doc.indexOf('\n') <= 0
    else
      while match = HEREDOC_INDENT.exec doc
        attempt = match[1]
        indent = attempt if indent is null or 0 < attempt.length < indent.length
    doc = doc.replace /// \n #{indent} ///g, '\n' if indent
    doc = doc.replace /^\n/, '' unless herecomment
    doc

  # A source of ambiguity in our grammar used to be parameter lists in function
  # definitions versus argument lists in function calls. Walk backwards, tagging
  # parameters specially in order to make things easier for the parser.
  tagParameters: ->
    return this if @tag() isnt ')'
    stack = []
    {tokens} = this
    i = tokens.length
    tokens[--i][0] = 'PARAM_END'
    while tok = tokens[--i]
      switch tok[0]
        when ')'
          stack.push tok
        when '(', 'CALL_START'
          if stack.length then stack.pop()
          else if tok[0] is '('
            tok[0] = 'PARAM_START'
            return this
          else return this
    this

  # Close up all remaining open blocks at the end of the file.
  closeIndentation: ->
    @outdentToken @indent

  # Matches a balanced group such as a single or double-quoted string. Pass in
  # a series of delimiters, all of which must be nested correctly within the
  # contents of the string. This method allows us to have strings within
  # interpolations within strings, ad infinitum.
  balancedString: (str, end) ->
    continueCount = 0
    stack = [end]
    for i in [1...str.length]
      if continueCount
        --continueCount
        continue
      switch letter = str.charAt i
        when '\\'
          ++continueCount
          continue
        when end
          stack.pop()
          unless stack.length
            return str[0..i]
          end = stack[stack.length - 1]
          continue
      if end is '}' and letter in ['"', "'"]
        stack.push end = letter
      else if end is '}' and letter is '{'
        stack.push end = '}'
      else if end is '"' and prev is '#' and letter is '{'
        stack.push end = '}'
      prev = letter
    @error "missing #{ stack.pop() }, starting"

  # Expand variables and expressions inside double-quoted strings using
  # Ruby-like notation for substitution of arbitrary expressions.
  #
  #     "Hello #{name.capitalize()}."
  #
  # If it encounters an interpolation, this method will recursively create a
  # new Lexer, tokenize the interpolated contents, and merge them into the
  # token stream.
  interpolateString: (str, options = {}) ->
    {heredoc, regex} = options
    tokens = []
    pi = 0
    i  = -1
    while letter = str.charAt i += 1
      if letter is '\\'
        i += 1
        continue
      unless letter is '#' and str.charAt(i+1) is '{' and
             (expr = @balancedString str[i + 1..], '}')
        continue
      tokens.push ['NEOSTRING', str[pi...i]] if pi < i
      inner = expr[1...-1]
      if inner.length
        nested = new Lexer().tokenize inner, line: @line, rewrite: off
        nested.pop()
        nested.shift() if nested[0]?[0] is 'TERMINATOR'
        if len = nested.length
          if len > 1
            nested.unshift ['(', '(', @line]
            nested.push    [')', ')', @line]
          tokens.push ['TOKENS', nested]
      i += expr.length
      pi = i + 1
    tokens.push ['NEOSTRING', str[pi..]] if i > pi < str.length
    return tokens if regex
    return @token 'STRING', '""' unless tokens.length
    tokens.unshift ['', ''] unless tokens[0][0] is 'NEOSTRING'
    @token '(', '(' if interpolated = tokens.length > 1
    for [tag, value], i in tokens
      @token '+', '+' if i
      if tag is 'TOKENS'
        @tokens.push value...
      else
        @token 'STRING', @makeString value, '"', heredoc
    @token ')', ')' if interpolated
    tokens

  # Pairs up a closing token, ensuring that all listed pairs of tokens are
  # correctly balanced throughout the course of the token stream.
  pair: (tag) ->
    unless tag is wanted = last @ends
      @error "unmatched #{tag}" unless 'OUTDENT' is wanted
      # Auto-close INDENT to support syntax like this:
      #
      #     el.click((event) ->
      #       el.hide())
      #
      @indent -= size = last @indents
      @outdentToken size, true
      return @pair tag
    @ends.pop()

  # Helpers
  # -------

  # Add a token to the results, taking note of the line number.
  token: (tag, value) ->
    @tokens.push [tag, value, @line]

  # Peek at a tag in the current token stream.
  tag: (index, tag) ->
    (tok = last @tokens, index) and if tag then tok[0] = tag else tok[0]

  # Peek at a value in the current token stream.
  value: (index, val) ->
    (tok = last @tokens, index) and if val then tok[1] = val else tok[1]

  # Are we in the midst of an unfinished expression?
  unfinished: ->
    LINE_CONTINUER.test(@chunk) or
    @tag() in ['\\', '.', 'UNARY', 'MATH', '+', '-', 'SHIFT', 'RELATION'
               'COMPARE', 'LOGIC', 'EXTENDS']

  # Converts newlines for string literals.
  escapeLines: (str, heredoc) ->
    str.replace MULTILINER, if heredoc then '\\n' else ''

  # Constructs a string token by escaping quotes and newlines.
  makeString: (body, quote, heredoc) ->
    return quote + quote unless body
    body = body.replace /\\([\s\S])/g, (match, contents) ->
      if contents in ['\n', quote] then contents else match
    body = body.replace /// #{quote} ///g, '\\$&'
    quote + @escapeLines(body, heredoc) + quote

  # Throws a syntax error on the current `@line`.
  error: (message) ->
    throw SyntaxError "#{message} on line #{ @line + 1}"

# Constants
# ---------

RESERVED = [
  'true'
  'false'
  'in'
  'return'
  'break'
  'continue'
  'if'
  'else'
  'switch'
  'for'
  'while'
  'do'
  'then'
  'unless'
  'until'
  'loop'
  'of'
  'by'
  'when'
]

exports.RESERVED = RESERVED

# Token matching regexes.
IDENTIFIER = /// ^
  ( [$A-Za-z_\x7f-\uffff][$\w\x7f-\uffff]* )
  ( [^\n\S]* : (?![:=]) )?  # Is this a property name?
///

NUMBER     = ///
  ^ 0b[01]+    |              # binary
  ^ 0o[0-7]+   |              # octal
  ^ 0x[\da-f]+ |              # hex
  ^ \d+                       # decimal
///i

HEREDOC    = /// ^ ("""|''') ([\s\S]*?) (?:\n[^\n\S]*)? \1 ///

OPERATOR   = /// ^ (
  ?: [-=]>             # function
   | [-+*/%:<>&|^!?=]= # compound assign / compare
   | >>>=?             # zero-fill right shift
   | ([-+:])\1         # doubles
   | ([&|<>])\2=?      # logic / shift
   | \?\.              # soak access
   | \.{2,3}           # range or splat
) ///

WHITESPACE = /^\ +/

COMMENT    = /^###([^#][\s\S]*?)(?:###[^\n\S]*|(?:###)?$)|^(?:\s*#(?!##[^#]).*)+/

CODE       = /^[-=]>/

MULTI_DENT = /^(?:\n\ *)+/

SIMPLESTR  = /^'[^\\']*(?:\\.[^\\']*)*'/

# Token cleaning regexes.
MULTILINER      = /\n/g

HEREDOC_INDENT  = /\n+([^\n\S]*)/g

HEREDOC_ILLEGAL = /\*\//

LINE_CONTINUER  = /// ^ \s* (?: , | \??\.(?![.\d]) | :: ) ///

TRAILING_SPACES = /\s+$/

# Compound assignment tokens.
COMPOUND_ASSIGN = [
  '-=', '+=', '/=', '*=', '%=', '||=', '&&=', '?=', '<<=', '>>=', '>>>=', '&=', '^=', '|='
]

ASSIGN = ['=', ':=']

# Unary tokens.
UNARY   = ['!', '~', 'NEW', 'TYPEOF', 'DELETE', 'DO']

# Logical tokens.
LOGIC   = ['&&', '||', '&', '|', '^']

# Bit-shifting tokens.
SHIFT   = ['<<', '>>', '>>>']

# Comparison tokens.
COMPARE = ['==', '!=', '<', '>', '<=', '>=']

# Mathematical tokens.
MATH    = ['*', '/', '%']

# Relational tokens that are negatable with `not` prefix.
RELATION = ['IN', 'OF', 'INSTANCEOF']

# Boolean tokens.
BOOL = ['TRUE', 'FALSE']

# Tokens which a regular expression will never immediately follow, but which
# a division operator might.
#
# See: http://www.mozilla.org/js/language/js20-2002-04/rationale/syntax.html#regular-expressions
#
# Our list is shorter, due to sans-parentheses method calls.
NOT_REGEX = ['NUMBER', 'BOOL', '++', '--', ']']

# If the previous token is not spaced, there are more preceding tokens that
# force a division parse:
NOT_SPACED_REGEX = NOT_REGEX.concat ')', '}', 'IDENTIFIER', 'STRING'

# Tokens which could legitimately be invoked or indexed. An opening
# parentheses or bracket following these tokens will be recorded as the start
# of a function invocation or indexing operation.
CALLABLE  = ['IDENTIFIER', 'STRING', ')', ']', '}', '::']
INDEXABLE = CALLABLE.concat 'NUMBER', 'BOOL'

# Tokens that, when immediately preceding a `WHEN`, indicate that the `WHEN`
# occurs at the start of a line. We disambiguate these from trailing whens to
# avoid an ambiguity in the grammar.
LINE_BREAK = ['INDENT', 'OUTDENT', 'TERMINATOR']
