||| SPDX-License-Identifier: MPL-2.0
||| Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
|||
||| Coaptation sound core — SKELETON (build-path step 6). NOT yet wired to the
||| runner. Declares the dependent-typed shape of the descriptile↔contractile
||| face-off: obligations (Clause), evidence (Fact), the witness relation, and the
||| totality of Coverage — where an unwitnessed Must is a compile-time error, not a
||| forgotten check. The Nickel comparator (coapt.ncl) is the AUTHORITATIVE reading
||| today; this core is a forward declaration of its types, to be graduated to real,
||| content-bearing proof obligations in a later session.
module Coaptation

import Data.Vect
import Data.Fin

||| The six normative contractile verbs.
public export
data Verb = Intend | Must | Trust | Adjust | Dust | Bust

||| The descriptive families that emit evidence (the descriptiles).
public export
data Family = CLADE | STATE | ECOSYSTEM | AGENTIC | ANCHOR

||| A contractile obligation, indexed by its verb.
public export
data Clause : Verb -> Type where
  MkClause : (id : String) -> (v : Verb) -> Clause v

||| A descriptive fact, indexed by its family.
public export
data Fact : Family -> Type where
  MkFact : (id : String) -> (f : Family) -> Fact f

||| Existential wrappers so heterogeneous clauses/facts share one vector spine.
public export
SomeClause : Type
SomeClause = (v : Verb ** Clause v)

public export
SomeFact : Type
SomeFact = (f : Family ** Fact f)

||| The correspondence: inhabited iff a fact witnesses an obligation. The single
||| constructor here is a PLACEHOLDER; soundness-critical Must/Trust correspondences
||| graduate to real, content-bearing proof obligations — the whole reason for
||| putting the core in Idris2.
public export
data Witnesses : SomeClause -> SomeFact -> Type where
  Attests : (c : SomeClause) -> (x : SomeFact) -> Witnesses c x

||| A coverage hole: an obligation with no witnessing fact.
public export
data Gap : SomeClause -> Type where
  NoWitness : (c : SomeClause) -> Gap c

||| Coverage is TOTAL by construction: for every obligation in the vector, either a
||| gap or a witnessing fact. A `Must` left without a witness cannot typecheck — the
||| obligation vector indexes the evidence vector, so the hole is a type error.
public export
Coverage : {n : Nat} -> Vect n SomeClause -> Type
Coverage cs = (i : Fin n) -> Either (Gap (index i cs)) (x : SomeFact ** Witnesses (index i cs) x)

||| The trivial total covering (everything a gap) — demonstrates the construction
||| typechecks. The real comparator replaces each `Left (NoWitness …)` with a
||| `Right (fact ** proof)` exactly where descriptive evidence attests the clause.
public export
allGaps : {n : Nat} -> (cs : Vect n SomeClause) -> Coverage cs
allGaps cs = \i => Left (NoWitness (index i cs))
