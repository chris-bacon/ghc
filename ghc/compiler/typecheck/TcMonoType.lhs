%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[TcMonoType]{Typechecking user-specified @MonoTypes@}

\begin{code}
#include "HsVersions.h"

module TcMonoType ( tcPolyType, tcMonoType, tcMonoTypeKind, tcContext ) where

IMP_Ubiq(){-uitous-}

import HsSyn		( PolyType(..), MonoType(..), Fake )
import RnHsSyn		( RenamedPolyType(..), RenamedMonoType(..), 
			  RenamedContext(..), RnName(..),
			  isRnLocal, isRnClass, isRnTyCon
			)

import TcMonad		hiding ( rnMtoTcM )
import TcEnv		( tcLookupTyVar, tcLookupClass, tcLookupTyCon, 
			  tcTyVarScope, tcTyVarScopeGivenKinds
			)
import TcKind		( TcKind, mkTcTypeKind, mkBoxedTypeKind,
			  mkTcArrowKind, unifyKind, newKindVar,
			  kindToTcKind
			)
import Type		( GenType, SYN_IE(Type), SYN_IE(ThetaType), 
			  mkTyVarTy, mkTyConTy, mkFunTy, mkAppTy, mkSynTy,
			  mkSigmaTy, mkDictTy
			)
import TyVar		( GenTyVar, SYN_IE(TyVar) )
import Class		( cCallishClassKeys )
import TyCon		( TyCon )
import TysWiredIn	( mkListTy, mkTupleTy )
import Unique		( Unique )
import PprStyle
import Pretty
import Util		( zipWithEqual, panic{-, pprPanic ToDo:rm-} )
\end{code}


tcMonoType and tcMonoTypeKind
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

tcMonoType checks that the type really is of kind Type!

\begin{code}
tcMonoType :: RenamedMonoType -> TcM s Type

tcMonoType ty
  = tcMonoTypeKind ty			`thenTc` \ (kind,ty) ->
    unifyKind kind mkTcTypeKind		`thenTc_`
    returnTc ty
\end{code}

tcMonoTypeKind does the real work.  It returns a kind and a type.

\begin{code}
tcMonoTypeKind :: RenamedMonoType -> TcM s (TcKind s, Type)

tcMonoTypeKind (MonoTyVar name)
  = tcLookupTyVar name	`thenNF_Tc` \ (kind,tyvar) ->
    returnTc (kind, mkTyVarTy tyvar)
    

tcMonoTypeKind (MonoListTy ty)
  = tcMonoType ty	`thenTc` \ tau_ty ->
    returnTc (mkTcTypeKind, mkListTy tau_ty)

tcMonoTypeKind (MonoTupleTy tys)
  = mapTc tcMonoType  tys	`thenTc` \ tau_tys ->
    returnTc (mkTcTypeKind, mkTupleTy (length tys) tau_tys)

tcMonoTypeKind (MonoFunTy ty1 ty2)
  = tcMonoType ty1	`thenTc` \ tau_ty1 ->
    tcMonoType ty2	`thenTc` \ tau_ty2 ->
    returnTc (mkTcTypeKind, mkFunTy tau_ty1 tau_ty2)

tcMonoTypeKind (MonoTyApp name tys)
  | isRnLocal name	-- Must be a type variable
  = tcLookupTyVar name			`thenNF_Tc` \ (kind,tyvar) ->
    tcMonoTyApp kind (mkTyVarTy tyvar) tys

  | otherwise {-isRnTyCon name-} 	-- Must be a type constructor
  = tcLookupTyCon name			`thenNF_Tc` \ (kind,maybe_arity,tycon) ->
    case maybe_arity of
	Just arity -> tcSynApp name kind arity tycon tys	-- synonum
	Nothing	   -> tcMonoTyApp kind (mkTyConTy tycon) tys	-- newtype or data

--  | otherwise
--  = pprPanic "tcMonoTypeKind:" (ppr PprDebug name)
	
-- for unfoldings only:
tcMonoTypeKind (MonoForAllTy tyvars_w_kinds ty)
  = tcTyVarScopeGivenKinds names tc_kinds (\ tyvars ->
	tcMonoTypeKind ty		`thenTc` \ (kind, ty') ->
	unifyKind kind mkTcTypeKind	`thenTc_`
	returnTc (mkTcTypeKind, ty')
    )
  where
    (rn_names, kinds) = unzip tyvars_w_kinds
    names    = map de_rn rn_names
    tc_kinds = map kindToTcKind kinds
    de_rn (RnName n) = n

-- for unfoldings only:
tcMonoTypeKind (MonoDictTy class_name ty)
  = tcMonoTypeKind ty			`thenTc` \ (arg_kind, arg_ty) ->
    tcLookupClass class_name		`thenNF_Tc` \ (class_kind, clas) ->
    unifyKind class_kind arg_kind	`thenTc_`
    returnTc (mkTcTypeKind, mkDictTy clas arg_ty)
\end{code}

Help functions for type applications
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
\begin{code}
tcMonoTyApp fun_kind fun_ty tys
  = mapAndUnzipTc tcMonoTypeKind tys	`thenTc`    \ (arg_kinds, arg_tys) ->
    newKindVar				`thenNF_Tc` \ result_kind ->
    unifyKind fun_kind (foldr mkTcArrowKind result_kind arg_kinds)	`thenTc_`
    returnTc (result_kind, foldl mkAppTy fun_ty arg_tys)

tcSynApp name syn_kind arity tycon tys
  = mapAndUnzipTc tcMonoTypeKind tys	`thenTc`    \ (arg_kinds, arg_tys) ->
    newKindVar				`thenNF_Tc` \ result_kind ->
    unifyKind syn_kind (foldr mkTcArrowKind result_kind arg_kinds)	`thenTc_`

	-- Check that it's applied to the right number of arguments
    checkTc (arity == n_args) (err arity)				`thenTc_`
    returnTc (result_kind, mkSynTy tycon arg_tys)
  where
    err arity = arityErr "Type synonym constructor" name arity n_args
    n_args    = length tys
\end{code}


Contexts
~~~~~~~~
\begin{code}

tcContext :: RenamedContext -> TcM s ThetaType
tcContext context = mapTc tcClassAssertion context

tcClassAssertion (class_name, tyvar_name)
  = checkTc (canBeUsedInContext class_name)
	    (naughtyCCallContextErr class_name)	`thenTc_`

    tcLookupClass class_name		`thenNF_Tc` \ (class_kind, clas) ->
    tcLookupTyVar tyvar_name		`thenNF_Tc` \ (tyvar_kind, tyvar) ->

    unifyKind class_kind tyvar_kind	`thenTc_`

    returnTc (clas, mkTyVarTy tyvar)
\end{code}

HACK warning: Someone discovered that @CCallable@ and @CReturnable@
could be used in contexts such as:
\begin{verbatim}
foo :: CCallable a => a -> PrimIO Int
\end{verbatim}

Doing this utterly wrecks the whole point of introducing these
classes so we specifically check that this isn't being done.

\begin{code}
canBeUsedInContext :: RnName -> Bool
canBeUsedInContext n
  = isRnClass n && not (uniqueOf n `elem` cCallishClassKeys)
\end{code}

Polytypes
~~~~~~~~~
\begin{code}
tcPolyType :: RenamedPolyType -> TcM s Type
tcPolyType (HsForAllTy tyvar_names context ty)
  = tcTyVarScope names (\ tyvars ->
	tcContext context	`thenTc` \ theta ->
	tcMonoType ty		`thenTc` \ tau ->
	returnTc (mkSigmaTy tyvars theta tau)
    )
  where
    names = map de_rn tyvar_names
    de_rn (RnName n) = n
\end{code}

Errors and contexts
~~~~~~~~~~~~~~~~~~~
\begin{code}
naughtyCCallContextErr clas_name sty
  = ppSep [ppStr "Can't use class", ppr sty clas_name, ppStr "in a context"]
\end{code}
