#include "ws_access.h"

Ws* ws_flatten( Ws* ws, Ws*(*recurse)(W*) ){
    return ws_rfilter(ws, recurse, w_keep_all);
}

Ws* ws_filter(Ws* ws, bool(*criterion)(W*)){
    return ws_rfilter(ws, ws_recurse_none, criterion);
}

// Find all {label,manifold} couplets
Ws* get_manifolds(Ws* ws){
    return ws_rfilter(ws, ws_recurse_most, w_is_manifold);
}

Ws* get_tpaths(Ws* ws){
    return ws_rfilter(ws, ws_recurse_none, w_is_tpath);
}

bool w_is_tpath(W* w){
    return w ? w->cls == T_PATH : false;
}

bool w_is_manifold(W* w){
    return w ? w->cls == C_MANIFOLD : false;
}

bool w_is_type(W* w){
    return w ? w->cls == T_TYPE : false;
}

bool w_is_composon(W* w){
    return w ? w->cls == C_COMPOSON : false;
}

Ws* ws_split_couplet(W* c){
    Ws* result = NULL;
    W* paths = g_lhs(c);
    switch(paths->cls){
        case K_LIST:
            {
                for(W* p = g_ws(paths)->head; p; p = p->next){
                    W* nc = w_isolate(c);
                    w_clone_value(nc); // so s_lhs doesn't change c
                    s_lhs(nc, p);
                    result = ws_add(result, nc);
                }
            }
            break;
        case K_PATH:
        case K_LABEL:
        case K_NAME:
            result = ws_add(result, c); 
            break;
        default:
            fprintf(stderr, "ERROR: invalid lhs type in couplet (%s:%d)", __func__, __LINE__);
            break;
    }
    return result;
}

// === nextval functions ============================================

W* w_nextval_always(W* w, W* p){ return p->next; }

W* w_nextval_never(W* w, W* p){ return p; }

/* p a modifier (e.g. effect).
 * w a node into which we are recursing
 *
 * if w is a path, we need to pop the top level of p's lhs.
 */
W* w_nextval_ifpath(W* w, W* p) {
    W* next = NULL;
    if(w->cls == T_PATH && ws_length(g_ws(g_lhs(p))) > 1){
        W* lhs = g_lhs(p);
        switch(lhs->cls){
            case K_PATH:
                next = w_isolate(p);
                s_ws(g_lhs(next), ws_tail(g_ws(lhs)));
                break;
            case K_LIST:
                next = NULL;
                fprintf(stderr, "Not supported (%s:%d)", __func__, __LINE__);
                break;
            default:
                next = NULL;
                break;
        }
    } else {
        next = w_isolate(p);
    }
    return next;
}

// === filter criteria ==============================================
// ------------------------------------------------------------------

bool w_keep_all(W* w){
    return true;
}

// === recursion rules ==============================================
// NOTE: recursion rules are splits
// ------------------------------------------------------------------

Ws* ws_recurse_most(W* w){
    if(!w) return NULL;
    Ws* rs = NULL;
    switch(get_value_type(w->cls)){
        case V_WS:
            rs = ws_add_val(rs, P_WS, g_ws(w));
            break;
        case V_COUPLET:
            {
                W* lhs = g_lhs(w);
                if(w_is_recursive(lhs)){
                    rs = ws_add_val(rs, P_WS, g_ws(lhs));
                }
                W* rhs = g_rhs(w);
                if(w_is_recursive(rhs)){
                    rs = ws_add_val(rs, P_WS, g_ws(rhs));
                }
            }
        default:
            break;
    }
    return rs;
}

Ws* ws_recurse_ws(W* w){
    if(!w) return NULL;
    Ws* rs = NULL;
    switch(get_value_type(w->cls)){
        case V_WS:
            rs = ws_add_val(rs, P_WS, g_ws(w));
            break;
        default:
            break;
    }
    return rs;
}

Ws* ws_recurse_none(W* w){
    return NULL;
}

Ws* ws_recurse_composition(W* w){
    if(!w) return NULL;
    Ws* rs = NULL;
    switch(w->cls){
        case C_COMPOSON:
        case C_NEST:
        case C_DEREF:
            rs = ws_add_val(rs, C_NEST, g_ws(w));
            break;
        case T_PATH:
            rs = ws_add_val(rs, C_NEST, g_ws(g_rhs(w)));
            break;
        default:
            return NULL;
    }
    return rs;
}

Label* _ws_get_label_from_lhs(W* a){
    if(!a) return NULL;
    Label* label = NULL;
    switch(a->cls){
        case K_NAME:
            label = label_new_set(strdup(g_string(a)), NULL);
            break;
        case K_LABEL:
            label = g_label(a);
            break;
        case K_PATH:
            label = g_ws(a) ? g_label(g_ws(a)->head) : NULL;
            break;
        case K_LIST:
            label = NULL;
            fprintf(stderr, "Recursion into K_LIST not supported (%s:%d)", __func__, __LINE__);
            break;
        default:
            label = NULL;
            fprintf(stderr, "Illegal left hand side (%s:%d)", __func__, __LINE__);
            break;
    }
    return label;
}

bool ws_cmp_lhs(W* a, W* b){

    Label* a_label = _ws_get_label_from_lhs(g_lhs(a));
    Label* b_label = _ws_get_label_from_lhs(g_lhs(b));

    return label_cmp(a_label, b_label);
}

Ws* ws_recurse_path(W* w, W* p){

    w_assert_type(p, V_COUPLET);

    switch(w->cls){
        case C_NEST:
            return g_ws(w);
        case T_PATH:
            return
                ws_length(g_ws(g_lhs(p))) == 1 || ws_cmp_lhs(w, p) ?
                g_ws(g_rhs(w)) : NULL;
        default:
            return NULL;
    }
}
