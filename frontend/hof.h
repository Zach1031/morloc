#ifndef __HOF_H__
#define __HOF_H__

#include "ws.h"

// Recursively moves through a Ws, accumulating W that meet a criterion into a flat list
Ws* ws_rfilter(
    Ws*,
    Ws*(*recurse)(W*),
    bool(*criterion)(W*)
);

// Non-recursive filter
Ws* ws_filter(
    Ws*,
    bool(*criterion)(W*)
);

// Non-recursive parameterized filter
Ws* ws_pfilter(Ws*, W*, bool(*criterion)(W*, W*));

// Parameterized version of ws_rfilter
Ws* ws_prfilter(
    Ws*,
    W*,
    Ws*(*recurse)(W*, W*),
    bool(*criterion)(W*, W*),
    W*(*nextval)(W*, W*)
);


// like ws_prfilter, but modifies rather than filtering.
void ws_prmod(
    Ws* ws,
    W* p,
    Ws*(*recurse)(W*, W*),
    bool(*criterion)(W*, W*),
    void(*mod)(W*, W*),
    W*(*nextval)(W*, W*)
);

void ws_recursive_reduce_mod(
    Ws* ws,
    Ws*(*recurse)(W*),
    bool(*l_criterion)(W*),
    bool(*r_criterion)(W*),
    void(*mod)(W*, W*)
);

// maps ws_prmod over parameter list ps
void ws_map_pmod(Ws* xs, Ws* ps, void(*pmod)(Ws*, W*));

/* Turns one couplet into a list of couplets, each with a single path (lhs). */
Ws* ws_split_couplet(W*);

/* A 'split' takes one thing and returns several:
 *
 * split :: a -> [b]
 *
 * map_split maps a split over a list and flattens the list:
 *
 * map_split :: [a] -> (a -> [b]) -> [b]
 *
 * Notice the flattening, the output isn't `[[b]]`
 *
 * contrast this to a simple map:
 *
 * map :: [a] -> (a -> b) -> [b]
 */
Ws* ws_map_split(Ws* ws, Ws*(*split)(W*));

// Maps over 1, 2, or 3 variables. All combinations are considered, that is,
// ws_2mod is quadratic and ws_3mod is cubic.
void ws_mod(Ws*, void(*mod)(W*));
void ws_2mod(Ws*, Ws*, void(*mod)(W*, W*));
void ws_3mod(Ws*, Ws*, Ws*, void(*mod)(W*, W*, W*));

// calls mod(xs[i], ys[i]) for all i. If as and bs are of unequal length, scream.
void ws_zip_mod(Ws* xs, Ws* ys, void(*mod)(W* x, W* y));
// stateful zip apply
W* ws_szap(Ws* xs, Ws* ys, W* st, W*(*mod)(W* x, W* y, W* st));

// Recurse along ws according to `recurse`. Perform function `mod` on all w if
// `criterion`. ws in `mod` are processed in the context of `ps`, which may,
// for example, be a symbol table. 
void ws_ref_rmod(
    Ws* ws,
    Ws* ps,
    Ws*(*recurse)(W*),
    bool(*criterion)(W*),
    void(*mod)(W*, Ws*)
);

// Recursive Conditional Modifier
void ws_rcmod(
    Ws* ws,
    Ws*(*recurse)(W*),
    bool(*criterion)(W*),
    void(*mod)(W*)
);

// Stateful Conditional Recursive Apply
W* ws_scrap(
    Ws* ws,
    W* st,
    Ws*(*recurse)(W*),
    bool(*criterion)(W*),
    W*(*mod)(W* w, W* st)
);

void ws_filter_mod(
    Ws* top,
    Ws*(*xfilter)(Ws*),
    void(*mod)(W* x)
);

void ws_filter_2mod(
    Ws* top,
    Ws*(*xfilter)(Ws*),
    Ws*(*yfilter)(Ws*),
    void(*mod)(W* x, W* y)
);

void ws_filter_3mod(
    Ws* top,
    Ws*(*xfilter)(Ws*),
    Ws*(*yfilter)(Ws*),
    Ws*(*zfilter)(Ws*),
    void(*mod)(W* x, W* y, W* z)
);

// Removing nesting in a list (as specified by the recursion rule).
// This is just a wrapper for ws_rfilter, with criterion := w_keep_all.
Ws* ws_flatten(Ws*, Ws*(*recurse)(W*));

// recurse rules
Ws* ws_recurse_ws(W*);   // recurse into V_WS
Ws* ws_recurse_most(W*); // recurse into V_WS and V_COUPLET (but not manifolds)
Ws* ws_recurse_none(W*); // no recursion
Ws* ws_recurse_composition(W*); // recurse into T_PATH and C_NEST
// parameterized recurse rules
Ws* ws_recurse_path(W*, W*);

// criteria functions
bool w_is_manifold(W*);
bool w_is_type(W*);
bool w_is_composon(W*);
bool w_keep_all(W*);

// nextval functions
W* w_nextval_always(W* p, W* w);
W* w_nextval_never(W* p, W* w);
W* w_nextval_ifpath(W* p, W* w);


#endif
