%top{
/*---------------------------------------------------------------------------------------
 * Named queries scanner
 * It returns back names and/or values of named queries from PGNQFILE file
 *
 * MODE_LIST: only list query names
 * MODE_FIND: stops at first query which matches the searched query name
 * MODE_EXECUTE: same as MODE_FIND, but also replaces positional arguments with values, 
 *               for later execution
 * MODE_DETAILED: returns all query names + all their bodies
 *
 * C-style comments have special treatment, because we dont want interpret placeholders
 * inside them
 *------------------------------------------------------------------------------------------
 */
  #include "postgres_fe.h"
  #include "common.h"
  #include "fe_utils/conditional.h"
  #include "fe_utils/psqlscan_int.h"
  #include "fe_utils/string_utils.h"
  #include "nqscan.h"
}
%option reentrant
%option 8bit
%option never-interactive
%option noinput
%option nounput
%option noyywrap 
%option warn
%option prefix="nq_yy"
%option nodefault

%{
  /* our "extra" data for scanner */
  typedef struct NQLexStruct {
    NQQueryInfo *qinfo;
    PQExpBuffer curBuffer; 
    const char *qToFind;
    bool found;
  } NQLexStruct;
  #define YY_DECL int nq_yylex(yyscan_t yyscanner, NQMode mode, NQLexStruct *extra, const char **args, int argc)
  YY_DECL;
  void NQQueryInfoDestroy(NQQueryInfo *qinfo);
  static NQQueryInfo* NQQueryInfoCreate(void);
  static yyscan_t yyscan_t_create(FILE *nqfile);
  static NQLexStruct NQLexStructCreate(const char *qname);
  #define NQNAME_LEN 5
%}

%x mlist
%x mfind
%x mdetailed
%x mexecute
%x comments


nqnewline		                         	[\n\r]                  
nqend                                 "--nq:end"
nqname                                "--nq:"[A-Za-z0-9_]+


%{
  int previous_state = 0;

%}

%%
{nqend}  
{nqname}  {
          if (mode == MODE_FIND) {
            if (strcmp(yytext+NQNAME_LEN, extra->qToFind) == 0){
              BEGIN(mfind);
            }
          } else if(mode == MODE_EXECUTE){
              if (strcmp(yytext+NQNAME_LEN, extra->qToFind) == 0){
              BEGIN(mexecute);
            }
          } else if (mode  == MODE_LIST) {
            NQQueryInfo *qinfo;
            qinfo = NQQueryInfoCreate();
            Assert(qinfo != NULL);
            qinfo->name = strndup(yytext+NQNAME_LEN,  yyleng-NQNAME_LEN);
            qinfo->next = extra->qinfo;
            extra->qinfo = qinfo;
            BEGIN(mlist);
          } else if (mode  == MODE_DETAILED){
            NQQueryInfo *qinfo;
            qinfo = NQQueryInfoCreate();
            Assert(qinfo != NULL);
            qinfo->name = strndup(yytext+NQNAME_LEN,  yyleng-NQNAME_LEN);
            qinfo->next = extra->qinfo;
            extra->qinfo = qinfo;
            BEGIN(mdetailed);
          }
       }
<mlist>{
  {nqend}   {BEGIN(INITIAL);}
}

<mfind,mexecute>{nqend} {
                          extra->found = true;
                          return 0;
                        }

<mdetailed>{nqend} {
          Assert(extra->qinfo != NULL);
          Assert(extra->curBuffer->data != NULL);
          Assert(extra->curBuffer->len != 0);
          extra->qinfo->value = strdup(extra->curBuffer->data);
          resetPQExpBuffer(extra->curBuffer);
          BEGIN(INITIAL);
        }
<mfind,mdetailed>(.+|{nqnewline}) {
                /* don't prepend useless newlines... but match them anyway, because they can be part of query */
                if (! (extra->curBuffer->len == 0 && yyleng == 1)){
                   appendBinaryPQExpBuffer(extra->curBuffer, yytext, yyleng);
                }

              }
<mexecute>[^@\n\r/]+|{nqnewline} {
                /* don't prepend useless newlines... but match them anyway, because they can be part of query */
                if (! (extra->curBuffer->len == 0 && yyleng == 1)){
                   appendBinaryPQExpBuffer(extra->curBuffer, yytext, yyleng);
                }
              }
<mexecute>"/*" {previous_state = mexecute; BEGIN(comments);} 
<mexecute>"/". {appendBinaryPQExpBuffer(extra->curBuffer, yytext, yyleng);} 
<mexecute>"@{"[0-9]{1,2}"}" {   
                      int val;
                      char cpy[3] = {'\0'};
                      cpy[0] = *(yytext + 2);
                      cpy[1] = *(yytext + 3) != '}' ? *(yytext + 3) : '\0';
                      val = atoi(cpy);
                      if (val <= 32 && val >=0) {
                        if (argc <= val){
                          fprintf(stderr, "This query requires at least %i positional arguments, but %i were given.\n", val+1, argc);
                          return 1;
                        } else {
                          /* replace for ex "@{1}" with second argument */
                          appendPQExpBufferStr(extra->curBuffer, args[val]);
                        }

                      }
                    }
<mexecute>"@".+  { appendBinaryPQExpBuffer(extra->curBuffer, yytext, yyleng);}
<comments>{
  [^*\n\r]*
  "*"+[^*/\n\r]*
  "*"+"/"         {BEGIN(previous_state);}

}
<*>([^@\r\n]+|{nqnewline})
<*>"@"
<*>"--".+


%%
/* return the definition of a particular query, with args substituted */
NQQueryInfo* 
NQScanExecute(FILE *nqfile, const char* qname, const char **args, int argc, int *err){
  int result = 0;
  NQQueryInfo *out;
  yyscan_t scanner =  yyscan_t_create(nqfile);
  NQLexStruct extra = NQLexStructCreate(qname);
  result = nq_yylex(scanner, MODE_EXECUTE, &extra, args, argc);
  *err = result;
  if (result == 0){
    if (extra.found){
      out = NQQueryInfoCreate();
      out->value = strndup(extra.curBuffer->data, extra.curBuffer->len);
    } else {
      out = NULL;
    }
  } else {
    out = NULL;
  }

  destroyPQExpBuffer(extra.curBuffer);
  yylex_destroy(scanner);
  return out;
}

/* return a list of all query names */
NQQueryInfo* 
NQScanList(FILE *nqfile){
  yyscan_t scanner = yyscan_t_create(nqfile);
  NQLexStruct extra = NQLexStructCreate(NULL);
  nq_yylex(scanner, MODE_LIST, &extra, NULL, 0);
  destroyPQExpBuffer(extra.curBuffer);
  yylex_destroy(scanner);
  return extra.qinfo;
}

/* find a query by name, return its definition */
NQQueryInfo* 
NQScanFind(FILE *nqfile, const char *qToFind){
  NQQueryInfo *out;
  yyscan_t scanner =  yyscan_t_create(nqfile);
  NQLexStruct extra = NQLexStructCreate(qToFind);
  nq_yylex(scanner, MODE_FIND, &extra, NULL, 0);
  if (extra.found){
    out = NQQueryInfoCreate();
    out->value = strndup(extra.curBuffer->data, extra.curBuffer->len);
  } else {
    out = NULL;
  }
  destroyPQExpBuffer(extra.curBuffer);
  yylex_destroy(scanner);
  return out;
}

/* returns all query names and their definitions */
NQQueryInfo* 
NQScanDetailed(FILE *nqfile){
  yyscan_t scanner =  yyscan_t_create(nqfile);
  NQLexStruct extra = NQLexStructCreate(NULL);
  nq_yylex(scanner, MODE_DETAILED, &extra, NULL, 0);
  destroyPQExpBuffer(extra.curBuffer);
  yylex_destroy(scanner);
  return extra.qinfo;
}

void 
NQQueryInfoDestroy(NQQueryInfo *qinfo) {
  if (qinfo->name != NULL) free(qinfo->name);
  if (qinfo->value != NULL) free(qinfo->value);
  free(qinfo);
}

static NQLexStruct 
NQLexStructCreate(const char *qname){
  NQLexStruct extra;
  extra.qinfo = NULL;
  extra.curBuffer = createPQExpBuffer();
  extra.found = false;
  extra.qToFind = qname;
  return extra;
}

static yyscan_t 
yyscan_t_create(FILE *nqfile){
  yyscan_t scanner;
  yylex_init(&scanner);
  Assert(nqfile != NULL);
  yyset_in(nqfile, scanner);
  return scanner;
}

static NQQueryInfo* 
NQQueryInfoCreate(){
  NQQueryInfo* out;
  out = (NQQueryInfo*) malloc(sizeof(NQQueryInfo));
  out->name = NULL;
  out->value = NULL;
  out->next = NULL;
  return out;
}
