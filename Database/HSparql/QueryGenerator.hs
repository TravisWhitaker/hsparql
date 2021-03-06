
-- |The query generator DSL for SPARQL, used when connecting to remote
--  endpoints.
module Database.HSparql.QueryGenerator
    ( -- * Creating Queries
      createSelectQuery
    , createConstructQuery
    , createAskQuery
    , createUpdateQuery
    , createDescribeQuery
    -- * Query Actions
    , prefix
    , var
    , Database.HSparql.QueryGenerator.triple
    , constructTriple
    , askTriple
    , updateTriple
    , describeIRI
    , optional
    , union
    , filterExpr

    -- ** Duplicate handling
    , distinct
    , reduced

    -- ** Limit handling
    , limit

    -- ** Order handling
    , orderNext
    , orderNextAsc
    , orderNextDesc

    -- ** Auxiliary
    , (.:.)
    , iriRef

    -- * Term Manipulation

    -- ** Operations
    , (.+.), (.-.), (.*.), (./.)

    -- ** Relations
    , (.==.), (.!=.), (.<.), (.>.), (.<=.), (.>=.)

    -- ** Negation
    , notExpr

    -- ** Builtin Functions
    , str
    , lang
    , langMatches
    , datatype
    , bound
    , sameTerm
    , isIRI
    , isURI
    , isBlank
    , isLiteral
    , regex

    -- * Printing Queries
    , qshow

    -- * Types
    , Query
    , Variable
    , VarOrNode(..)
    , Pattern
    , SelectQuery(..)
    , ConstructQuery(..)
    , AskQuery(..)
    , UpdateQuery(..)
    , DescribeQuery(..)
    )
where

import Control.Monad.State
import Data.List (intercalate)
import qualified Data.Text as T
import Data.RDF


-- State monads

-- |The 'State' monad applied to 'QueryData'.
type Query a = State QueryData a

-- |Execute a 'Query' action, starting with the empty 'queryData', then process
-- the resulting 'QueryData'.
execQuery :: Query a -> (QueryData -> b) -> b
execQuery q f = f $ execState q queryData

-- |Execute a 'Select Query' action, returning the 'String' representation of the query.
createSelectQuery :: Query SelectQuery -> String
createSelectQuery q = execQuery specifyVars qshow
    where specifyVars :: Query ()
          specifyVars = do query <- q
                           modify $ \s -> s { vars = queryVars query , queryType = SelectType }

-- |Execute a 'Construct Query' action, returning the 'String' representation of the query.
createConstructQuery :: Query ConstructQuery -> String
createConstructQuery q = execQuery specifyType qshow
    where specifyType :: Query ()
          specifyType = do
           query <- q
           modify $ \s -> s { constructTriples = queryConstructs query, queryType = ConstructType }

-- |Execute a 'Ask Query' action, returning the 'String' representation of the query.
createAskQuery :: Query AskQuery -> String
createAskQuery q = execQuery specifyType qshow
    where specifyType :: Query ()
          specifyType = do
           query <- q
           modify $ \s -> s { askTriples = queryAsk query, queryType = AskType }

-- |Execute a 'Update Query' action, returning the 'String' representation of the query.
createUpdateQuery :: Query UpdateQuery -> String
createUpdateQuery q = execQuery specifyType qshow
    where specifyType :: Query ()
          specifyType = do
           query <- q
           modify $ \s -> s { updateTriples = queryUpdate query, queryType = UpdateType }

-- |Execute a 'Describe Query' action, returning the 'String' representation of the query.
createDescribeQuery :: Query DescribeQuery -> String
createDescribeQuery q = execQuery specifyType qshow
    where specifyType :: Query ()
          specifyType = do
           query <- q
           modify $ \s -> s { describeURI = Just (queryDescribe query), queryType = DescribeType }

-- Manipulate data within monad

-- |Add a prefix to the query, given an IRI reference, and return it.
prefix :: T.Text -> IRIRef -> Query Prefix
prefix pre (AbsoluteIRI node) = do
                let p = Prefix pre node
                modify $ \s -> s { prefixes = p : prefixes s }
                return p

-- |Create and return a variable to the query, usable in later expressions.
var :: Query Variable
var = do n <- gets varsIdx
         modify $ \s -> s { varsIdx = n + 1 }
         return $ Variable n

-- |Restrict the query to only results for which values match constants in this
--  triple, or for which the variables can be bound.
triple :: (TermLike a, TermLike b, TermLike c) => a -> b -> c -> Query Pattern
triple a b c = do
    let t = QTriple (varOrTerm a) (varOrTerm b) (varOrTerm c)
    modify $ \s -> s { pattern = appendPattern t (pattern s) }
    return t


constructTriple :: (TermLike a, TermLike b, TermLike c) => a -> b -> c -> Query Pattern
constructTriple a b c = do
    let t = QTriple (varOrTerm a) (varOrTerm b) (varOrTerm c)
    modify $ \s -> s { constructTriples = appendTriple t (constructTriples s) }
    return t

askTriple :: (TermLike a, TermLike b, TermLike c) => a -> b -> c -> Query Pattern
askTriple a b c = do
    let t = QTriple (varOrTerm a) (varOrTerm b) (varOrTerm c)
    modify $ \s -> s { askTriples = appendTriple t (askTriples s) }
    return t

updateTriple :: (TermLike a, TermLike b, TermLike c) => a -> b -> c -> Query Pattern
updateTriple a b c = do
    let t = QTriple (varOrTerm a) (varOrTerm b) (varOrTerm c) -- TODO: should only allow terms
    modify $ \s -> s { updateTriples = appendTriple t (updateTriples s) }
    return t

describeIRI :: IRIRef -> Query IRIRef
describeIRI newIri = do
    modify $ \s -> s { describeURI = Just newIri }
    return newIri


-- |Add optional constraints on matches. Variable bindings within the optional
--  action are lost, so variables must always be defined prior to opening the
--  optional block.
optional :: Query a -> Query Pattern
optional q = do
    -- Determine the patterns by executing the action on a blank QueryData, and
    -- then pulling the patterns out from there.
    let option  = execQuery q $ OptionalGraphPattern . pattern
    modify $ \s -> s { pattern = appendPattern option (pattern s) }
    return option

-- |Add a union structure to the query pattern. As with 'optional' blocks,
--  variables must be defined prior to the opening of any block.
union :: Query a -> Query b -> Query Pattern
union q1 q2 = do 
    let p1    = execQuery q1 pattern
        p2    = execQuery q2 pattern
        union' = UnionGraphPattern p1 p2
    modify $ \s -> s { pattern = appendPattern union' (pattern s) }
    return union'

-- |Restrict results to only those for which the given expression is true.
filterExpr :: (TermLike a) => a -> Query Pattern
filterExpr e = do
    let f = Filter (expr e)
    modify $ \s -> s { pattern = appendPattern f (pattern s) }
    return f

-- Random auxiliary

-- |Form a 'Node', with the 'Prefix' and reference name.
(.:.) :: Prefix -> T.Text -> IRIRef
(.:.) = PrefixedName


-- Duplicate handling

-- |Set duplicate handling to 'Distinct'. By default, there are no reductions.
distinct :: Query Duplicates
distinct = do modify $ \s -> s { duplicates = Distinct }
              gets duplicates

-- |Set duplicate handling to 'Reduced'. By default, there are no reductions.
reduced :: Query Duplicates
reduced = do modify $ \s -> s { duplicates = Reduced }
             gets duplicates

-- |Set limit handling to the given value.  By default, there are no limits.
--  Note: negative numbers cause no query results to be returned.
limit :: Int -> Query Limit
limit n = do modify $ \s -> s { limits = Limit n }
             gets limits

-- Order handling

-- |Alias of 'orderNextAsc'.
orderNext :: (TermLike a) => a -> Query ()
orderNext = orderNextAsc 

-- |Order the results, after any previous ordering, based on the term, in
--  ascending order.
orderNextAsc :: (TermLike a) => a -> Query ()
orderNextAsc x  = modify $ \s -> s { ordering = ordering s ++ [Asc  $ expr x] }

-- |Order the results, after any previous ordering, based on the term, in
--  descending order.
orderNextDesc :: (TermLike a) => a -> Query ()
orderNextDesc x = modify $ \s -> s { ordering = ordering s ++ [Desc $ expr x] }

-- Permit variables and values to seemlessly be put into argument for 'triple'
-- and similar functions
class TermLike a where
  varOrTerm :: a -> VarOrTerm

  expr :: a -> Expr
  expr = VarOrTermExpr . varOrTerm

instance TermLike Variable where
  varOrTerm = Var

instance TermLike IRIRef where
  varOrTerm = Term . IRIRefTerm

instance TermLike Expr where
  varOrTerm = error "cannot use an expression as a term"
  expr = id

instance TermLike Integer where
  varOrTerm = Term . NumericLiteralTerm
  expr = NumericExpr . NumericLiteralExpr

instance TermLike T.Text where
  varOrTerm = Term . RDFLiteralTerm . plainL

instance TermLike (T.Text, T.Text) where
  varOrTerm (s, lang') = Term . RDFLiteralTerm $ plainLL s lang'

instance TermLike (T.Text, IRIRef) where
  varOrTerm (s, ref) = Term . RDFLiteralTerm $ typedL s (getFQN ref)

instance TermLike Bool where
  varOrTerm = Term . BooleanLiteralTerm

instance TermLike VarOrNode where
  varOrTerm (Var' v)              = Var v
  varOrTerm (RDFNode n@(UNode _)) = (Term . IRIRefTerm . AbsoluteIRI) n
  varOrTerm (RDFNode (LNode lv))  = (Term . RDFLiteralTerm) lv
  -- TODO: non-exhaustive: missing BNode, BNodeGen

-- Operations
operation :: (TermLike a, TermLike b) => Operation -> a -> b -> Expr
operation op x y = NumericExpr $ OperationExpr op (expr x) (expr y)

-- |Add two terms.
(.+.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.+.) = operation Add

-- |Find the difference between two terms.
(.-.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.-.) = operation Subtract

-- |Multiply two terms.
(.*.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.*.) = operation Multiply

-- |Divide two terms.
(./.) :: (TermLike a, TermLike b) => a -> b -> Expr
(./.) = operation Divide

-- Relations
relation :: (TermLike a, TermLike b) => Relation -> a -> b -> Expr
relation rel x y = RelationalExpr rel (expr x) (expr y)

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their equivalence.
(.==.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.==.) = relation Equal

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their equivalence.
(.!=.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.!=.) = relation NotEqual

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their relative value.
(.<.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.<.) = relation LessThan

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their relative value.
(.>.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.>.) = relation GreaterThan

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their relative value.
(.<=.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.<=.) = relation LessThanOrEqual

-- |Create an expression which tests the relationship of the two operands,
--  evaluating their relative value.
(.>=.) :: (TermLike a, TermLike b) => a -> b -> Expr
(.>=.) = relation GreaterThanOrEqual

-- Negation

-- |Negate any term-like expression, for use, e.g., in filtering.
notExpr :: (TermLike a) => a -> Expr
notExpr = NegatedExpr . expr

-- Builtin Functions
type BuiltinFunc1 = (TermLike a) => a -> Expr
builtinFunc1 :: Function -> BuiltinFunc1
builtinFunc1 f x = BuiltinCall f [expr x]

type BuiltinFunc2 = (TermLike a, TermLike b) => a -> b -> Expr
builtinFunc2 :: Function -> BuiltinFunc2
builtinFunc2 f x y = BuiltinCall f [expr x, expr y]

str :: BuiltinFunc1
str = builtinFunc1 StrFunc

lang :: BuiltinFunc1
lang = builtinFunc1 LangFunc

langMatches :: BuiltinFunc2
langMatches = builtinFunc2 LangMatchesFunc

datatype :: BuiltinFunc1
datatype = builtinFunc1 DataTypeFunc

bound :: Variable -> Expr
bound x = BuiltinCall BoundFunc [expr x]

sameTerm :: BuiltinFunc2
sameTerm = builtinFunc2 SameTermFunc

isIRI :: BuiltinFunc1
isIRI = builtinFunc1 IsIRIFunc

isURI :: BuiltinFunc1
isURI = builtinFunc1 IsURIFunc

isBlank :: BuiltinFunc1
isBlank = builtinFunc1 IsBlankFunc

isLiteral :: BuiltinFunc1
isLiteral = builtinFunc1 IsLiteralFunc

regex :: BuiltinFunc2
regex = builtinFunc2 RegexFunc

-- Default QueryData
queryData :: QueryData
queryData = QueryData
    { prefixes   = []
    , varsIdx    = 0
    , vars       = []
    , queryType  = TypeNotSet
    , pattern    = GroupGraphPattern []
    , constructTriples = []
    , askTriples = []
    , updateTriples = []
    , describeURI = Nothing
    , duplicates = NoLimits
    , limits     = NoLimit
    , ordering   = []
    }



-- Query representation
class QueryShow a where
  -- |Convert most query-related types to a 'String', most importantly
  --  'QueryData's.
  qshow :: a -> String

data Duplicates = NoLimits | Distinct | Reduced

data Limit = NoLimit | Limit Int

data Prefix = Prefix T.Text Node

data Variable = Variable Int

data IRIRef = AbsoluteIRI Node
            | PrefixedName Prefix T.Text

iriRef :: T.Text -> IRIRef
iriRef uri = AbsoluteIRI $ unode uri

getFQN :: IRIRef -> T.Text
getFQN (AbsoluteIRI (UNode n)) = n
getFQN (PrefixedName (Prefix _ (UNode n)) s) = T.append n s

-- Should support numeric literals, too
data GraphTerm = IRIRefTerm IRIRef
               | RDFLiteralTerm LValue
               | NumericLiteralTerm Integer
               | BooleanLiteralTerm Bool

data VarOrTerm = Var Variable
               | Term GraphTerm

-- |Enables programmatic construction of triples where it is not known in
-- advance which parts of the triple will be variables and which will be
-- 'Node's.
data VarOrNode = Var' Variable
               | RDFNode Node

data Operation = Add | Subtract | Multiply | Divide

data NumericExpr = NumericLiteralExpr Integer
                 | OperationExpr Operation Expr Expr

data Relation = Equal | NotEqual | LessThan | GreaterThan | LessThanOrEqual | GreaterThanOrEqual

data Function = StrFunc | LangFunc | LangMatchesFunc | DataTypeFunc | BoundFunc
              | SameTermFunc | IsIRIFunc | IsURIFunc | IsBlankFunc
              | IsLiteralFunc | RegexFunc

data Expr = OrExpr [Expr]
          | AndExpr [Expr]
          | NegatedExpr Expr
          | RelationalExpr Relation Expr Expr
          | NumericExpr NumericExpr
          | BuiltinCall Function [Expr]
          | VarOrTermExpr VarOrTerm

data Pattern = QTriple VarOrTerm VarOrTerm VarOrTerm
             | Filter Expr
             | OptionalGraphPattern GroupGraphPattern
             | UnionGraphPattern GroupGraphPattern GroupGraphPattern
data GroupGraphPattern = GroupGraphPattern [Pattern]

data OrderBy = Asc Expr
             | Desc Expr

-- Auxiliary, but fairly useful
-- TODO don't add to end
appendPattern :: Pattern -> GroupGraphPattern -> GroupGraphPattern
appendPattern p (GroupGraphPattern ps) = GroupGraphPattern (ps ++ [p])

appendTriple :: a -> [a] -> [a]
appendTriple t ts = t : ts

data QueryData = QueryData
    { prefixes   :: [Prefix]
    , varsIdx    :: Int
    , vars       :: [Variable]
    , queryType  :: QueryType
    , pattern    :: GroupGraphPattern
    , constructTriples :: [Pattern] -- QTriple
    , askTriples :: [Pattern]
    , updateTriples :: [Pattern]
    , describeURI :: Maybe IRIRef
    , duplicates :: Duplicates
    , limits     :: Limit
    , ordering   :: [OrderBy]
    }


data QueryType = SelectType | ConstructType | AskType | UpdateType | DescribeType | TypeNotSet

data QueryForm = SelectForm QueryData | ConstructForm QueryData | AskForm QueryData | UpdateForm QueryData | DescribeForm QueryData

data ConstructQuery = ConstructQuery
    { queryConstructs :: [Pattern] }

data AskQuery = AskQuery
    { queryAsk :: [Pattern] }

data UpdateQuery = UpdateQuery
    { queryUpdate :: [Pattern] }

data SelectQuery = SelectQuery
    { queryVars :: [Variable] }

data DescribeQuery = DescribeQuery
    { queryDescribe :: IRIRef }


-- QueryShow instances
instance (QueryShow a) => QueryShow [a] where
  qshow xs = unwords $ map qshow xs

instance QueryShow Duplicates where
  qshow NoLimits = ""
  qshow Distinct = "DISTINCT"
  qshow Reduced  = "REDUCED"

instance QueryShow Limit where
  qshow NoLimit   = ""
  qshow (Limit n) = "Limit " ++ show n

instance QueryShow Node where
  qshow (UNode n) = "<" ++ T.unpack n ++ ">"

instance QueryShow Prefix where
  qshow (Prefix pre ref) = "PREFIX " ++ (T.unpack pre) ++ ": " ++ qshow ref

instance QueryShow Variable where
  qshow (Variable v) = "?x" ++ show v

instance QueryShow IRIRef where
  qshow (AbsoluteIRI n) = qshow n
  qshow (PrefixedName (Prefix pre _) s) = (T.unpack pre) ++ ":" ++ (T.unpack s)

instance QueryShow (Maybe IRIRef) where
  qshow (Just r) = qshow r
  qshow Nothing = ""

instance QueryShow LValue where
  qshow (PlainL s)        = "\"" ++ (T.unpack $ escapeQuotes s) ++ "\""
  qshow (PlainLL s lang') = "\"" ++ (T.unpack $ escapeQuotes s) ++ "\"@" ++ (T.unpack lang')
  qshow (TypedL s ref)    = "\"" ++ (T.unpack $ escapeQuotes s) ++ "\"^^" ++ (T.unpack ref)

instance QueryShow GraphTerm where
  qshow (IRIRefTerm ref)           = qshow ref
  qshow (RDFLiteralTerm s)         = qshow s
  qshow (BooleanLiteralTerm True)  = show "true"
  qshow (BooleanLiteralTerm False) = show "false"
  qshow (NumericLiteralTerm i)     = show i

instance QueryShow VarOrTerm where
  qshow (Var  v) = qshow v
  qshow (Term t) = qshow t

instance QueryShow Operation where
  qshow Add      = "+"
  qshow Subtract = "-"
  qshow Multiply = "*"
  qshow Divide   = "/"

instance QueryShow NumericExpr where
  qshow (NumericLiteralExpr n) = show n
  qshow (OperationExpr op x y) = qshow x ++ qshow op ++ qshow y

instance QueryShow Relation where
  qshow Equal              = "="
  qshow NotEqual           = "!="
  qshow LessThan           = "<"
  qshow GreaterThan        = ">"
  qshow LessThanOrEqual    = "<="
  qshow GreaterThanOrEqual = ">="

instance QueryShow Function where
  qshow StrFunc         = "STR"
  qshow LangFunc        = "LANG"
  qshow LangMatchesFunc = "LANGMATCHES"
  qshow DataTypeFunc    = "DATATYPE"
  qshow BoundFunc       = "BOUND"
  qshow SameTermFunc    = "sameTerm"
  qshow IsIRIFunc       = "isIRI"
  qshow IsURIFunc       = "isURI"
  qshow IsBlankFunc     = "isBlank"
  qshow IsLiteralFunc   = "isLiteral"
  qshow RegexFunc       = "REGEX"

instance QueryShow Expr where
  qshow (VarOrTermExpr vt) = qshow vt
  qshow e = "(" ++ qshow' e ++ ")"
    where qshow' (OrExpr es)        = intercalate " || " $ map qshow es
          qshow' (AndExpr es)       = intercalate " && " $ map qshow es
          qshow' (NegatedExpr e')   = '!' : qshow e'
          qshow' (RelationalExpr rel e1 e2) = qshow e1 ++ qshow rel ++ qshow e2
          qshow' (NumericExpr e')   = qshow e'
          qshow' (BuiltinCall f es) = qshow f ++ "(" ++ intercalate ", " (map qshow es) ++ ")"

instance QueryShow Pattern where
  qshow (QTriple a b c) = qshow [a, b, c] ++ " ."
  qshow (Filter e)     = "FILTER " ++ qshow e ++ " ."

  qshow (OptionalGraphPattern p)  = "OPTIONAL " ++ qshow p
  qshow (UnionGraphPattern p1 p2) = qshow p1 ++ " UNION " ++ qshow p2

instance QueryShow GroupGraphPattern where
  qshow (GroupGraphPattern ps) = "{" ++ qshow ps ++ "}"

instance QueryShow OrderBy where
  qshow (Asc e)  = "ASC(" ++ qshow e ++ ")"
  qshow (Desc e) = "DESC(" ++ qshow e ++ ")"


instance QueryShow QueryForm where
  qshow (SelectForm qd) =  unwords 
                        [ "SELECT"
                         , qshow (duplicates qd)
                         , qshow (vars qd)
                        ]

  qshow (ConstructForm qd) = "CONSTRUCT { " ++ qshow (constructTriples qd) ++ " }"

  qshow (AskForm qd) = "ASK { " ++ qshow (askTriples qd) ++ " }"

  qshow (UpdateForm qd) = "INSERT DATA { " ++ qshow (updateTriples qd) ++ " }"

  qshow (DescribeForm qd) = "DESCRIBE " ++ qshow (describeURI qd)

instance QueryShow QueryData where
  qshow qd = let whereStmt = unwords $
                              ["WHERE"
                              , qshow (pattern qd)
                              ] ++ case ordering qd of
                                      [] -> []
                                      os -> "ORDER BY" : map qshow os

                 query = case queryType qd of
                  SelectType -> 
                   unwords [ qshow (prefixes qd)
                           , qshow (SelectForm qd)
                           , whereStmt
                           , qshow (limits qd)
                           ]
                  ConstructType -> 
                   unwords [ qshow (prefixes qd)
                           , qshow (ConstructForm qd)
                           , whereStmt
                           ]
                  DescribeType -> 
                   unwords [ qshow (prefixes qd)
                           , qshow (DescribeForm qd)
                           , whereStmt
                           ]
                  AskType -> 
                   unwords [ qshow (prefixes qd)
                           , qshow (AskForm qd)
                           ]
                  UpdateType -> 
                   unwords [ qshow (prefixes qd)
                           , qshow (UpdateForm qd)
                           ]
             in query


-- Internal utilities
escapeQuotes :: T.Text -> T.Text
escapeQuotes = T.replace "\"" "\\\""
