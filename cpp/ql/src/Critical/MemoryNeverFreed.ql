/**
 * @name Memory is never freed
 * @description A function always returns before freeing memory that was allocated in the function. Freeing all memory allocated in the function before returning ties the lifetime of the memory blocks to that of the function call, making it easier to avoid and detect memory leaks.
 * @kind problem
 * @id cpp/memory-never-freed
 * @problem.severity warning
 * @tags efficiency
 *       security
 *       external/cwe/cwe-401
 */

import MemoryFreed

from Expr alloc
where isAllocationExpr(alloc) and not allocMayBeFreed(alloc)
select alloc, "This memory is never freed"
