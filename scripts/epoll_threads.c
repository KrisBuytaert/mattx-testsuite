// epoll_threads: one thread blocks in epoll_wait(-1) on an eventfd, a second thread writes
// the eventfd once a second. Prints a line per event. Used to check that a migrated
// process keeps making progress while one of its threads sits in a long epoll_wait.
#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

static int efd;

static void *writer(void *arg) {
    (void)arg;
    for (;;) {
        sleep(1);
        uint64_t one = 1;
        if (write(efd, &one, sizeof(one)) != sizeof(one)) perror("write eventfd");
    }
    return NULL;
}

int main(int argc, char **argv) {
    int total = argc > 1 ? atoi(argv[1]) : 120;
    efd = eventfd(0, 0);
    int ep = epoll_create1(0);
    struct epoll_event ev = { .events = EPOLLIN, .data.fd = efd };
    if (efd < 0 || ep < 0 || epoll_ctl(ep, EPOLL_CTL_ADD, efd, &ev) < 0) { perror("setup"); return 1; }
    pthread_t t;
    pthread_create(&t, NULL, writer, NULL);
    printf("epoll_threads pid=%d started\n", getpid()); fflush(stdout);
    for (int n = 1; n <= total; n++) {
        struct epoll_event out;
        int r = epoll_wait(ep, &out, 1, -1);
        if (r < 0) { perror("epoll_wait"); continue; }
        uint64_t v;
        if (read(efd, &v, sizeof(v)) < 0) perror("read eventfd");
        printf("event %d (epoll_wait=%d)\n", n, r); fflush(stdout);
    }
    printf("epoll_threads DONE\n"); fflush(stdout);
    return 0;
}
