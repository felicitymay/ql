/**
 * @name Indirect imports per file
 * @description The number of modules imported by this file - either directly by an import statement,
 *              or indirectly (by being imported by an imported module).
 * @kind treemap
 * @id py/transitive-imports-per-file
 * @treemap.warnOn highValues
 * @metricType file
 * @metricAggregate avg max
 * @tags modularity
 */
import python

from ModuleObject m, int n
where n = count(ModuleObject imp | imp = m.getAnImportedModule+() and imp != m)
select m.getModule(), n