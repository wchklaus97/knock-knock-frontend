#include <node_api.h>
#include <stddef.h>

#ifdef __APPLE__
#include <dlfcn.h>
#include <stdbool.h>
#include <string.h>
#include <sys/types.h>

#define VAB_PT_DENY_ATTACH 31

typedef int (*vab_ptrace_function)(int request, pid_t pid, void *address,
                                   int data);

_Static_assert(sizeof(vab_ptrace_function) == sizeof(void *),
               "unsupported Darwin function pointer representation");
#endif

static napi_value deny_attach(napi_env env, napi_callback_info info) {
  (void)info;

#ifdef __APPLE__
  static bool installed = false;
  if (!installed) {
    dlerror();
    void *symbol = dlsym(RTLD_DEFAULT, "ptrace");
    const char *symbol_error = dlerror();
    if (symbol_error != NULL || symbol == NULL) {
      napi_throw_error(env, "ERR_MCP_DENY_ATTACH_UNAVAILABLE",
                       "Darwin ptrace symbol unavailable");
      return NULL;
    }

    vab_ptrace_function ptrace_function = NULL;
    memcpy(&ptrace_function, &symbol, sizeof(ptrace_function));
    if (ptrace_function(VAB_PT_DENY_ATTACH, 0, NULL, 0) == -1) {
      napi_throw_error(env, "ERR_MCP_DENY_ATTACH_FAILED",
                       "ptrace(PT_DENY_ATTACH) failed");
      return NULL;
    }
    installed = true;
  }
#endif

  napi_value result;
  if (napi_get_boolean(env, true, &result) != napi_ok) {
    napi_throw_error(env, "ERR_MCP_DENY_ATTACH_RESULT",
                     "Unable to create anti-attach result");
    return NULL;
  }
  return result;
}

static napi_value initialize(napi_env env, napi_value exports) {
  napi_value function;
  if (napi_create_function(env, "denyAttach", NAPI_AUTO_LENGTH, deny_attach,
                           NULL, &function) != napi_ok) {
    return NULL;
  }
  if (napi_set_named_property(env, exports, "denyAttach", function) != napi_ok) {
    return NULL;
  }
  return exports;
}

NAPI_MODULE(macos_deny_attach, initialize)
