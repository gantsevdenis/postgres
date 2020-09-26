#ifndef _NQSCAN_H_
#define _NQSCAN_H_ 1

#include "fe_utils/psqlscan_int.h"
#include "postgres_fe.h"
typedef enum NQMode {
  MODE_LIST, 
  MODE_FIND,
  MODE_DETAILED,
  MODE_EXECUTE
} NQMode;

typedef struct NQQueryInfo {
  char* name; 
  char* value;
  struct NQQueryInfo* next;
} NQQueryInfo;

/* return the definition of a particular query, with args substituted */
extern NQQueryInfo* NQScanExecute(FILE *nqfile, const char* qname, const char **args, int argc, int *err);

/* return a list of all query names */
extern NQQueryInfo* NQScanList(FILE *nqfile);

/* find a query by name, return its definition */
extern NQQueryInfo* NQScanFind(FILE *nqfile, const char *qToFind);

/* returns all query names and their definitions */
extern NQQueryInfo* NQScanDetailed(FILE *nqfile);

/* free()s content of qinfo, as well as itself*/
extern void NQQueryInfoDestroy(NQQueryInfo *qinfo);
#endif
