/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team 1998-2008
 *
 * Generational garbage collector
 *
 * Documentation on the architecture of the Garbage Collector can be
 * found in the online commentary:
 * 
 *   http://hackage.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/GC
 *
 * ---------------------------------------------------------------------------*/

#ifndef GCTHREAD_H
#define GCTHREAD_H

#include "OSThreads.h"

/* -----------------------------------------------------------------------------
   General scheme
   
   ToDo: move this to the wiki when the implementation is done.

   We're only going to try to parallelise the copying GC for now.  The
   Plan is as follows.

   Each thread has a gc_thread structure (see below) which holds its
   thread-local data.  We'll keep a pointer to this in a thread-local
   variable, or possibly in a register.

   In the gc_thread structure is a step_workspace for each step.  The
   primary purpose of the step_workspace is to hold evacuated objects;
   when an object is evacuated, it is copied to the "todo" block in
   the thread's workspace for the appropriate step.  When the todo
   block is full, it is pushed to the global step->todos list, which
   is protected by a lock.  (in fact we intervene a one-place buffer
   here to reduce contention).

   A thread repeatedly grabs a block of work from one of the
   step->todos lists, scavenges it, and keeps the scavenged block on
   its own ws->scavd_list (this is to avoid unnecessary contention
   returning the completed buffers back to the step: we can just
   collect them all later).

   When there is no global work to do, we start scavenging the todo
   blocks in the workspaces.  This is where the scan_bd field comes
   in: we can scan the contents of the todo block, when we have
   scavenged the contents of the todo block (up to todo_bd->free), we
   don't want to move this block immediately to the scavd_list,
   because it is probably only partially full.  So we remember that we
   have scanned up to this point by saving the block in ws->scan_bd,
   with the current scan pointer in ws->scan.  Later, when more
   objects have been copied to this block, we can come back and scan
   the rest.  When we visit this workspace again in the future,
   scan_bd may still be the same as todo_bd, or it might be different:
   if enough objects were copied into this block that it filled up,
   then we will have allocated a new todo block, but *not* pushed the
   old one to the step, because it is partially scanned.

   The reason to leave scanning the todo blocks until last is that we
   want to deal with full blocks as far as possible.
   ------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
   Step Workspace
  
   A step workspace exists for each step for each GC thread. The GC
   thread takes a block from the todos list of the step into the
   scanbd and then scans it.  Objects referred to by those in the scan
   block are copied into the todo or scavd blocks of the relevant step.
  
   ------------------------------------------------------------------------- */

typedef struct step_workspace_ {
    step * step;		// the step for this workspace 
    struct gc_thread_ * gct;    // the gc_thread that contains this workspace

    // where objects to be scavenged go
    bdescr *     todo_bd;
    StgPtr       todo_free;            // free ptr for todo_bd
    StgPtr       todo_lim;             // lim for todo_bd

    bdescr *     buffer_todo_bd;     // buffer to reduce contention
                                     // on the step's todos list

    // where large objects to be scavenged go
    bdescr *     todo_large_objects;

    // Objects that have already been, scavenged.
    bdescr *     scavd_list;
    nat          n_scavd_blocks;     // count of blocks in this list

    // Partially-full, scavenged, blocks
    bdescr *     part_list;
    unsigned int n_part_blocks;      // count of above

    StgWord pad[5];

} step_workspace ATTRIBUTE_ALIGNED(64);
// align so that computing gct->steps[n] is a shift, not a multiply
// fails if the size is <64, which is why we need the pad above

/* ----------------------------------------------------------------------------
   GC thread object

   Every GC thread has one of these. It contains all the step specific
   workspaces and other GC thread local information. At some later
   point it maybe useful to move this other into the TLS store of the
   GC threads
   ------------------------------------------------------------------------- */

typedef struct gc_thread_ {
#ifdef THREADED_RTS
    OSThreadId id;                 // The OS thread that this struct belongs to
    Mutex      wake_mutex;
    Condition  wake_cond;          // So we can go to sleep between GCs
    rtsBool    wakeup;
    rtsBool    exit;
#endif
    nat thread_index;              // a zero based index identifying the thread

    bdescr * free_blocks;          // a buffer of free blocks for this thread
                                   //  during GC without accessing the block
                                   //   allocators spin lock. 

    StgClosure* static_objects;      // live static objects
    StgClosure* scavenged_static_objects;   // static objects scavenged so far

    lnat gc_count;                 // number of GCs this thread has done

    // block that is currently being scanned
    bdescr *     scan_bd;

    // --------------------
    // evacuate flags

    step *evac_step;               // Youngest generation that objects
                                   // should be evacuated to in
                                   // evacuate().  (Logically an
                                   // argument to evacuate, but it's
                                   // static a lot of the time so we
                                   // optimise it into a per-thread
                                   // variable).

    rtsBool failed_to_evac;        // failure to evacuate an object typically 
                                   // Causes it to be recorded in the mutable 
                                   // object list

    rtsBool eager_promotion;       // forces promotion to the evac gen
                                   // instead of the to-space
                                   // corresponding to the object

    lnat thunk_selector_depth;     // ummm.... not used as of now

#ifdef USE_PAPI
    int papi_events;
#endif

    // -------------------
    // stats

    lnat copied;
    lnat scanned;
    lnat any_work;
    lnat no_work;
    lnat scav_find_work;

    // -------------------
    // workspaces

    // array of workspaces, indexed by stp->abs_no.  This is placed
    // directly at the end of the gc_thread structure so that we can get from
    // the gc_thread pointer to a workspace using only pointer
    // arithmetic, no memory access.  This happens in the inner loop
    // of the GC, see Evac.c:alloc_for_copy().
    step_workspace steps[];
} gc_thread;


extern nat n_gc_threads;

extern gc_thread **gc_threads;

/* -----------------------------------------------------------------------------
   The gct variable is thread-local and points to the current thread's
   gc_thread structure.  It is heavily accessed, so we try to put gct
   into a global register variable if possible; if we don't have a
   register then use gcc's __thread extension to create a thread-local
   variable.

   Even on x86 where registers are scarce, it is worthwhile using a
   register variable here: I measured about a 2-5% slowdown with the
   __thread version.
   -------------------------------------------------------------------------- */

#define GLOBAL_REG_DECL(type,name,reg) register type name REG(reg);

#if defined(REG_Base) && !defined(i386_HOST_ARCH)
// on i386, REG_Base is %ebx which is also used for PIC, so we don't
// want to steal it

GLOBAL_REG_DECL(gc_thread*, gct, REG_Base)
#define DECLARE_GCT /* nothing */

#elif defined(REG_R1)

GLOBAL_REG_DECL(gc_thread*, gct, REG_R1)
#define DECLARE_GCT /* nothing */

#elif defined(__GNUC__)

extern __thread gc_thread* gct;
#define DECLARE_GCT __thread gc_thread* gct;

#else

#error Cannot find a way to declare the thread-local gct

#endif

#endif // GCTHREAD_H
