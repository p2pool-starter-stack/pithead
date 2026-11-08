#include "lmdb.h"
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RECORDS 1024
#define WORDS 256

static volatile sig_atomic_t stopping;

static void stop(int sig) {
    (void) sig;
    stopping = 1;
}

static void checked(int rc) {
    if (rc) {
        fprintf(stderr, "%s\n", mdb_strerror(rc));
        exit(1);
    }
}

static uint64_t verify(MDB_env *env) {
    MDB_txn *txn;
    MDB_dbi db;
    MDB_stat stat;
    MDB_val key, value;
    uint64_t generation;
    checked(mdb_txn_begin(env, NULL, MDB_RDONLY, &txn));
    checked(mdb_dbi_open(txn, NULL, 0, &db));
    key.mv_size = 10;
    key.mv_data = "generation";
    checked(mdb_get(txn, db, &key, &value));
    if (value.mv_size != sizeof(generation)) exit(2);
    memcpy(&generation, value.mv_data, sizeof(generation));
    if (!generation) exit(2);
    checked(mdb_stat(txn, db, &stat));
    if (stat.ms_entries != RECORDS + 1) exit(2);
    for (uint64_t i = 0; i < RECORDS; ++i) {
        key.mv_size = sizeof(i);
        key.mv_data = &i;
        checked(mdb_get(txn, db, &key, &value));
        if (value.mv_size != WORDS * sizeof(uint64_t)) exit(2);
        const uint64_t *words = value.mv_data;
        for (uint64_t j = 0; j < WORDS; ++j)
            if (words[j] != (generation ^ (i << 32) ^ j)) exit(2);
    }
    mdb_txn_abort(txn);
    return generation;
}

int main(int argc, char **argv) {
    MDB_env *env;
    MDB_txn *txn;
    MDB_dbi db;
    MDB_val key, value;
    uint64_t words[WORDS];
    if (argc != 3) return 2;
    int writing = !strcmp(argv[1], "seed") || !strcmp(argv[1], "write");
    if (!writing && strcmp(argv[1], "check") && strcmp(argv[1], "corrupt")) return 2;
    checked(mdb_env_create(&env));
    checked(mdb_env_set_mapsize(env, 128UL * 1024 * 1024));
    checked(mdb_env_open(env, argv[2], !writing && strcmp(argv[1], "corrupt") ? MDB_RDONLY : 0, 0600));
    if (!writing && !strcmp(argv[1], "check")) {
        printf("%llu\n", (unsigned long long) verify(env));
    } else if (!strcmp(argv[1], "corrupt")) {
        uint64_t index = 0;
        checked(mdb_txn_begin(env, NULL, 0, &txn));
        checked(mdb_dbi_open(txn, NULL, 0, &db));
        key.mv_size = sizeof(index);
        key.mv_data = &index;
        value.mv_size = sizeof(words);
        memset(words, 0, sizeof(words));
        value.mv_data = words;
        checked(mdb_put(txn, db, &key, &value, 0));
        checked(mdb_txn_commit(txn));
    } else {
        uint64_t first = !strcmp(argv[1], "seed") ? 1 : verify(env) + 1;
        if (signal(SIGTERM, stop) == SIG_ERR) return 2;
        for (uint64_t generation = first; !stopping; ++generation) {
            checked(mdb_txn_begin(env, NULL, 0, &txn));
            checked(mdb_dbi_open(txn, NULL, 0, &db));
            for (uint64_t i = 0; i < RECORDS; ++i) {
                for (uint64_t j = 0; j < WORDS; ++j) words[j] = generation ^ (i << 32) ^ j;
                key.mv_size = sizeof(i);
                key.mv_data = &i;
                value.mv_size = sizeof(words);
                value.mv_data = words;
                checked(mdb_put(txn, db, &key, &value, 0));
            }
            key.mv_size = 10;
            key.mv_data = "generation";
            value.mv_size = sizeof(generation);
            value.mv_data = &generation;
            checked(mdb_put(txn, db, &key, &value, 0));
            checked(mdb_txn_commit(txn));
            if (!strcmp(argv[1], "seed")) break;
            usleep(1000);
        }
    }
    mdb_env_close(env);
    return 0;
}
