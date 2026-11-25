/* A multi-threaded C program for Linux, linked statically against musl:
 * pthreads as any program uses them. Eight threads add to one counter
 * under a mutex, keep a count of their own in thread-local storage, and
 * hand a baton around with a condition variable; the main thread joins
 * them and checks every number. Prints what it found and exits with 0 if
 * all of it is right. */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define THREADS 8
#define ROUNDS 20000

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t turn_changed = PTHREAD_COND_INITIALIZER;
static long counter;
static int turn; /* whose turn it is to take the baton */
static int baton_passes;
static __thread long mine; /* each thread's own */
static pthread_barrier_t start;

static void *worker(void *arg) {
    long id = (long)arg;
    pthread_barrier_wait(&start); /* all at once */
    for (int i = 0; i < ROUNDS; i++) {
        pthread_mutex_lock(&lock);
        counter++;
        pthread_mutex_unlock(&lock);
        mine++;
    }
    /* The baton goes round in order of id, three times. */
    for (int lap = 0; lap < 3; lap++) {
        pthread_mutex_lock(&lock);
        while (turn != id) pthread_cond_wait(&turn_changed, &lock);
        turn = (turn + 1) % THREADS;
        baton_passes++;
        pthread_cond_broadcast(&turn_changed);
        pthread_mutex_unlock(&lock);
    }
    /* What this thread counted, and that nobody else's count got into it. */
    return (void *)(mine == ROUNDS ? id + 100 : -1);
}

int main(void) {
    pthread_t threads[THREADS];
    pthread_barrier_init(&start, NULL, THREADS + 1);
    for (long i = 0; i < THREADS; i++) {
        if (pthread_create(&threads[i], NULL, worker, (void *)i) != 0) {
            printf("threads: cannot create thread %ld\n", i);
            return 2;
        }
    }
    pthread_barrier_wait(&start);

    /* A timed wait that nothing ends: it must time out, not hang. */
    pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t never = PTHREAD_COND_INITIALIZER;
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_nsec += 50 * 1000 * 1000;
    if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
    pthread_mutex_lock(&m);
    int timed = pthread_cond_timedwait(&never, &m, &until);
    pthread_mutex_unlock(&m);

    int ok = 1;
    for (long i = 0; i < THREADS; i++) {
        void *result;
        if (pthread_join(threads[i], &result) != 0 || (long)result != i + 100) ok = 0;
    }
    printf("threads: %d threads, counter %ld of %ld, baton passed %d times, timed wait %s, main's own count %ld\n",
           THREADS, counter, (long)THREADS * ROUNDS, baton_passes, timed != 0 ? "timed out" : "did not time out", mine);
    if (counter != (long)THREADS * ROUNDS || baton_passes != 3 * THREADS || timed == 0 || mine != 0) ok = 0;
    printf("threads: %s\n", ok ? "all correct" : "WRONG");
    return ok ? 0 : 1;
}
