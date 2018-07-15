module Morloc.Parser (morlocScript) where

import Text.Parsec hiding (State, Parser)
import qualified Text.Parsec.Expr as TPE
import Control.Monad.State
import Control.Monad.Except (throwError)
import Data.List (intercalate)

import Morloc.Error
import Morloc.Syntax
import Morloc.State
import Morloc.Triple
import qualified Morloc.Lexer as Tok

-- | Parse a string of Morloc text into an AST. Catch lexical syntax errors.
morlocScript :: String -> ThrowsError [Triple]
morlocScript s =
  case runParser contents parserStateEmpty "<stdin>" s of
    Left err  -> throwError $ SyntaxError err
    Right val -> return val

-- (>>) :: f a -> f b -> f a
-- (<*) :: f a -> (a -> f b) -> f a
contents :: Parser [Triple]
contents = fmap concat (Tok.whiteSpace >> many top <* eof)

top :: Parser [Triple]
top =
      try (source'    <* optional (Tok.op ";") )
  <|> try (statement' <*           Tok.op ";"  )
  <|> try (import'    <* optional (Tok.op ";") )
  <?> "Top. Maybe you are missing a semicolon?"

-- | parses a 'source' header, returning the language
source' :: Parser [Triple]
source' = do
  -- id for this source
  Tok.reserved "source"
  -- get the language of the imported source
  lang <- Tok.stringLiteral
  -- get the path to the source file, if Nothing, then assume "vanilla"
  i <- getId <* setScope'
  path <- optionMaybe (Tok.reserved "from" >> Tok.stringLiteral)
  -- get the function imports with with optional aliases
  fs <- Tok.parens (sepBy importAs' Tok.comma)
  -- the statement is unambiguous even without a semicolon
  optional (Tok.op ";")

  return $ [
        (i, ":isa",  Str' ":source")
      , (i, ":lang", Str' lang)
    ] ++
      concat fs ++
      maybe [] (\p -> [(i, ":path", Str' p)]) path

  -- return $ case path of
  --   (Just p) -> SourceFile lang p fs
  --   Nothing  -> SourceLang lang fs
  where
    importAs' :: Parser [Triple] -- (String, Maybe String)
    importAs' = do
      -- quoting the function names allows them to have more arbitrary values,
      -- perhaps even including expressions that return functions (though this
      -- is probably bad practice).
      func <- Tok.stringLiteral
      -- the alias is especially important when the native function name is not
      -- legal Morloc syntax, for example an R function with a '.' in the name.
      alias <- optionMaybe (Tok.reserved "as" >> Tok.name)
      s <- getState
      j <- getId

      return $ [
            (j, ":imported_from", Id' (stateScope s))
          , (j, ":name", Str' func)
        ] ++
        maybe [] (\x -> [(j, ":alias", Str' x)]) alias

statement' :: Parser [Triple]
statement' =
      try signature
  <|> try declaration

import' :: Parser [Triple]
import' =
      try restrictedImport
  <|> try simpleImport

simpleImport :: Parser [Triple]
simpleImport = do
  Tok.reserved "import"
  path <- Tok.path
  qual <- optionMaybe (Tok.op "as" >> Tok.name)

  i <- getId
  return $ [
        (i, ":isa", Str' ":import")
      , (i, ":name", Str' (intercalate "." path))
    ] ++
    maybe [] (\q -> [(i, ":namespace", Str' q)]) qual

restrictedImport :: Parser [Triple]
restrictedImport = do
  Tok.reserved "from"
  path <- Tok.path
  Tok.reserved "import"
  -- TODO: I am also importing ontologies, how should that be handled?
  -- TODO: at very least, I am also importing types
  i <- getId <* setScope'
  functions <- Tok.parens (sepBy1 tripleName Tok.comma)

  return $ [
        (i, ":isa", Str' ":restricted_import")
      , (i, ":name", Str' (intercalate "." path))
    ] ++ adopt i functions

declaration :: Parser [Triple]
declaration = do
  varname <- Tok.name
  bndvars <- many tripleName
  Tok.op "="
  value <- expression

  i <- getId
  return $ [
        (i, ":isa", Str' "declaration")
      , (i, ":name", Str' varname)
    ] ++ adopt i bndvars
      ++ adopt i [value]

-- | function :: [input] -> output constraints
signature :: Parser [Triple]
signature = do
  i <- getId <* setScope'
  function <- Tok.name
  Tok.op "::"
  inputs <- sepBy1 mtype Tok.comma
  output <- optionMaybe (
      Tok.op "->" >>
      mtype
    )
  constraints <- option [] (
      Tok.reserved "where" >>
      Tok.parens (sepBy1 booleanExpr Tok.comma)
    )

  return $ [
        (i, ":isa", Str' ":signature")
      , (i, ":name", Str' function)
    ]
    ++ concat inputs
    ++ maybe [] (\x->x) output
    -- ++ constraints

listTag :: Subject -> Maybe String -> [(Subject, Relation, Object)] 
listTag i tag = maybe [] (\t -> [(i, ":label", Str' t)]) tag

mtype :: Parser [Triple]
mtype = fmap (\(RDF _ xs) -> xs) mtype'
  where

    mtype' :: Parser RDF
    mtype' =
            try specific' -- A ...
        <|> try generic'  -- a ...
        <|> try record'   -- A { ... }
        <|> try unambiguous'
        <?> "type"

    unambiguous' :: Parser RDF
    unambiguous' =
            try empty' -- ()
        <|> try paren' -- (a)
        <|> try tuple' -- (a, ...)
        <|> specific1  -- A
        <|> generic1   -- a
        <|> list'      -- [a]

    -- <name> <type> <type> ...
    specific' :: Parser RDF
    specific' = do
      l <- Tok.tag Tok.specificType
      n <- Tok.specificType
      i <- getId
      ns <- many1 unambiguous'
      return $ RDF i (
             [(i, ":isa", Str' ":type"), (i, ":name", Str' n)]
          ++ listTag i l
          ++ adopt i ns
        )

    -- Does parameterized generic even make sense?  Yes, say `f Int` where `f`
    -- is a generic collection of integers. Then you can map across it with any
    -- function of an Int.
    --
    -- <name> <type> <type> ...
    generic' :: Parser RDF
    generic' = do
      -- TODO - the genericType should automatically fail on keyword conflict
      notFollowedBy (Tok.reserved "where")
      l <- Tok.tag Tok.genericType
      n <- Tok.genericType
      i <- getId
      ns <- many1 unambiguous'
      return $ RDF i (
             [(i, ":isa", Str' ":generic"), (i, ":name", Str' n)]
          ++ (listTag i l)
          ++ (adopt i ns)
        )

    -- <name> <type> <type> ...
    specific1 :: Parser RDF
    specific1 = do
      l <- Tok.tag Tok.specificType
      n <- Tok.specificType
      i <- getId
      return $ RDF i (
             [(i, ":isa", Str' ":type"), (i, ":name", Str' n)]
          ++ listTag i l
        )

    -- <name> <type> <type> ...
    generic1 :: Parser RDF
    generic1 = do
      -- TODO - the genericType should automatically fail on keyword conflict
      notFollowedBy (Tok.reserved "where")
      l <- Tok.tag Tok.genericType
      n <- Tok.genericType
      i <- getId
      return $ RDF i (
             [(i, ":isa", Str' ":generic"), (i, ":name", Str' n)]
          ++ (listTag i l)
        )

    empty' :: Parser RDF
    empty' = do
      Tok.op "("
      Tok.op ")"
      i <- getId
      return $ RDF i [(i, ":isa", Str' ":empty")]

    paren' :: Parser RDF 
    paren' = Tok.parens mtype'

    tuple' :: Parser RDF
    tuple' = Tok.parens $ do
      i <- getId
      l <- Tok.tag (char '(')
      x <- mtype'
      Tok.op ","
      xs <- sepBy1 mtype' Tok.comma
      return $ RDF i (
             [(i, ":isa", Str' ":tuple")]
          ++ listTag i l
          ++ adopt i (x:xs)
        )

    -- [ <type> ]
    list' :: Parser RDF
    list' = do
      i <- getId
      l <- Tok.tag (char '[')
      s <- Tok.brackets mtype'
      return $ RDF i ([(i, ":isa", Str' ":list")] ++ listTag i l ++ adopt i [s])

    -- <name> { <name> :: <type>, <name> :: <type>, ... }
    record' :: Parser RDF
    record' = do
      l <- Tok.tag Tok.specificType
      n <- Tok.specificType
      i <- getId
      ns <- Tok.braces $ sepBy1 recordEntry' Tok.comma
      return $ RDF i (
             [ (i, ":isa", Str' ":record"), (i, ":name", Str' n)]
          ++ listTag i l
          ++ adopt i ns
        )

    -- (<name> = <type>)
    recordEntry' :: Parser RDF
    recordEntry' = do
      i <- getId
      n <- Tok.name
      Tok.op "::"
      ts <- mtype'
      return $ RDF i (
          [(i, ":isa", Str' ":tag"), (i, ":name", Str' n)] ++ adopt i [ts]
        )

mdata :: Parser RDF
mdata =  do
        try tripleBool          -- True | False
    <|> try tripleFloat         -- 1.1
    <|> try tripleInteger       -- 1
    <|> try tripleStringLiteral -- "yolo"
    <|> try list'               -- [ ...
    <|> try tuple'              -- ( ...
    <|> try record'             -- { ...
    <?> "literal data"
    where

      list' :: Parser RDF
      list' = do
        i <- getId
        xs <- Tok.brackets (sepBy mdata Tok.comma)
        return $ RDF i ([(i, ":isa", Str' "list")] ++ adopt i xs)

      tuple' = do
        i <- getId
        xs <- Tok.parens tuple''
        return $ RDF i ([(i, ":isa", Str' "tuple")] ++ adopt i xs)

      record' = do
        i <- getId
        xs <- Tok.braces (sepBy1 recordEntry' Tok.comma) 
        return $ RDF i ([(i, ":isa", Str' "record")] ++ adopt i xs)

      -- must have at least two elements
      tuple'' = do
        x <- mdata
        Tok.comma
        xs <- sepBy1 mdata Tok.comma
        return $ x:xs

      -- parse a tag/value pair
      recordEntry' = do
        i <- getId
        n <- Tok.name
        Tok.op "="
        t <- mdata
        return $ RDF i (
            [ (i, ":isa", Str' "recordEntry") 
            , (i, ":name", Str' n)
            ] ++ adopt i [t]
          )

expression :: Parser RDF
expression = do
  i <- getId
  x <- term'
  -- -- currently this just handles "."
  -- try (TPE.buildExpressionParser functionTable term')
  --     <|> term'
  --     <?> "an expression"
  return $ RDF i [(i, ":isa", Str' ":expression")]
  where
    term' =
          try (Tok.parens expression)
      <|> try application
      <|> try mdata

application :: Parser RDF
application = do
  i <- getId
  function <- Tok.parens expression <|> identifier'
  arguments <- sepBy term' Tok.whiteSpace
  return $ RDF i (
         [(i, ":isa", Str' ":application")]
      ++ adopt i [function]
      ++ adopt i arguments
    )
  where
    term' =
          try (Tok.parens expression)
      <|> try identifier'
      <|> try mdata

    identifier' = do
      i    <- getId
      x    <- Tok.name
      tag' <- Tok.tag Tok.name
      return $ RDF i ([(i, ":isa", Str' "XXX")] ++ listTag i tag')

booleanExpr :: Parser BExpr
booleanExpr =
      try booleanBinOp
  <|> try relativeExpr
  <|> try not'
  <|> try (Tok.parens booleanExpr)
  <|> try application'
  <?> "an expression that reduces to True/False"
  where
    not' = fmap NOT (Tok.reserved "not" >> booleanExpr)
    application' = do
      n <- Tok.name
      ns <- many Tok.name
      return $ BExprFunc n ns

booleanBinOp :: Parser BExpr
booleanBinOp = do
  a <- bterm'
  op <- Tok.logicalBinOp
  b <- bterm'
  return $ binop' op a b
  where
    bterm' =
            application'
        <|> bool'
        <|> Tok.parens booleanExpr
        <?> "boolean expression"

    application' = do
      n <- Tok.name
      ns <- many Tok.name
      return $ BExprFunc n ns

    bool' = fmap BExprBool Tok.boolean

    binop' op a b
      | op == "and" = AND a b
      | op == "or"  = OR  a b

relativeExpr :: Parser BExpr
relativeExpr = do
  a <- arithmeticExpr
  op <- Tok.relativeBinOp
  b <- arithmeticExpr
  return $ relop' op a b
  where
    relop' op a b
      | op == "==" = EQ' a b
      | op == "!=" = NE' a b
      | op == ">"  = GT' a b
      | op == "<"  = LT' a b
      | op == ">=" = GE' a b
      | op == "<=" = LE' a b

arithmeticExpr
  = TPE.buildExpressionParser arithmeticTable arithmeticTerm
  <?> "expression"

arithmeticTerm
  =
      Tok.parens arithmeticExpr
  <|> try access'
  -- <|> val'
  <|> var'
  <?> "simple expression. Currently only integers are allowed"
  where
    -- val' = fmap toExpr' mdata

    var' = do
      x <- Tok.name
      xs <- option [] (many arithmeticTerm)
      return $ AExprFunc x xs

    access' = do
      x <- Tok.name
      ids <- Tok.brackets (sepBy1 arithmeticExpr Tok.comma)
      return $ AExprAccess x ids

    toExpr' :: MData -> AExpr
    toExpr' (MInt x) = AExprInt x
    toExpr' (MNum x) = AExprReal x
    toExpr' _ = undefined

arithmeticTable
  = [
      [ prefix "-" Neg
      , prefix "+" Pos
      ]
    , [ binary "^"  Pow TPE.AssocRight
      ]
    , [ binary "*"  Mul TPE.AssocLeft
      , binary "/"  Div TPE.AssocLeft
      , binary "%"  Mod TPE.AssocLeft
      , binary "//" Quo TPE.AssocLeft
      ]
    , [ binary "+"  Add TPE.AssocLeft
      , binary "-"  Sub TPE.AssocLeft
      ]
  ]

functionTable = [[ binary "."  ExprComposition TPE.AssocRight]]

binary name fun assoc = TPE.Infix  (do{ Tok.op name; return fun }) assoc
prefix name fun       = TPE.Prefix (do{ Tok.op name; return fun })

triplePrimitive :: String -> Parser a -> (a -> Object) -> Parser RDF
triplePrimitive isa p f = do
  i <- getId
  n <- p
  return $ RDF i [(i, ":isa", Str' isa), (i, ":value", f n)]

tripleInteger       :: Parser RDF
tripleFloat         :: Parser RDF
tripleName          :: Parser RDF
tripleStringLiteral :: Parser RDF
tripleBool          :: Parser RDF

tripleInteger       = triplePrimitive ":integer" Tok.integer       Int'
tripleFloat         = triplePrimitive ":number"  Tok.float         Num'
tripleName          = triplePrimitive ":name"    Tok.name          Str'
tripleStringLiteral = triplePrimitive ":string"  Tok.stringLiteral Str'
tripleBool          = triplePrimitive ":boolean" Tok.boolean       Log'
