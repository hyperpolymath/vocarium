; SPDX-License-Identifier: MPL-2.0
;; guix.scm — GNU Guix package definition for vocarium
;; Usage: guix shell -f guix.scm

(use-modules (guix packages)
             (guix build-system gnu)
             (guix licenses))

(package
  (name "vocarium")
  (version "0.1.0")
  (source #f)
  (build-system gnu-build-system)
  (synopsis "Trope database: a store for vokeable particulars")
  (description
   "Vocarium is an experimental trope database: a structured store of
particularised property-instances (quality, bearer, context, record), their
transformation paths, grades, warrants, use-models, and verdicts.  It is the
storage component of the Haec / Vocarium / Hermeneia stack.")
  (home-page "https://github.com/hyperpolymath/vocarium")
  (license mpl2.0))
