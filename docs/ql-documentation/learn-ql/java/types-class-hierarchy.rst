Tutorial: Types and the class hierarchy
=======================================

Overview
--------

The standard QL library for Java represents Java types by means of the ``Type`` class and its various subclasses.

In particular, class ``PrimitiveType`` represents primitive types that are built into the Java language (such as ``boolean`` and ``int``), whereas ``RefType`` and its subclasses represent reference types, that is classes, interfaces, array types, and so on. This includes both types from the Java standard library (like ``java.lang.Object``) and types defined by non-library code.

Class ``RefType`` also models the class hierarchy: member predicates ``getASupertype`` and ``getASubtype`` allow you to find a reference type's immediate super types and sub types. For example, consider the following Java program:

.. code-block:: java

   class A {}

   interface I {}

   class B extends A implements I {}

Here, class ``A`` has exactly one immediate super type (``java.lang.Object``) and exactly one immediate sub type (``B``); the same is true of interface ``I``. Class ``B``, on the other hand, has two immediate super types (``A`` and ``I``), and no immediate sub types.

To determine ancestor types (including immediate super types, and also *their* super types, etc.), we can use transitive closure. For example, to find all ancestors of ``B`` in the example above, we could use the following query:

.. code-block:: ql

   import java

   from Class B
   where B.hasName("B")
   select B.getASupertype+()

➤ `See this in the query console <https://lgtm.com/query/674620010/>`__. If this query were run on the example snippet above, the query would return ``A``, ``I``, and ``java.lang.Object``.

   Tip

   If you want to see the location of ``B`` as well as ``A``, you can replace ``B.getASupertype+()`` with ``B.getASupertype*()`` and re-run the query.

Besides class hierarchy modeling, ``RefType`` also provides member predicate ``getAMember`` for accessing members (that is, fields, constructors and methods) declared in the type, and predicate ``inherits(Method m)`` for checking whether the type either declares or inherits a method ``m``.

Example: Finding problematic array casts
----------------------------------------

As an example of how to use the class hierarchy API, we can write a query that finds downcasts on arrays, that is, cases where an expression ``e`` of some type ``A[]`` is converted to type ``B[]``, such that ``B`` is a (not necessarily immediate) subtype of ``A``.

This kind of cast is problematic, since downcasting an array results in a runtime exception, even if every individual array element could be downcast. For example, the following code throws a ``ClassCastException``:

.. code-block:: java

   Object[] o = new Object[] { "Hello", "world" };
   String[] s = (String[])o;

If the expression ``e`` happens to actually evaluate to a ``B[]`` array, on the other hand, the cast will succeed:

.. code-block:: java

   Object[] o = new String[] { "Hello", "world" };
   String[] s = (String[])o;

In this tutorial, we do not try to distinguish these two cases. Our query should simply look for cast expressions ``ce`` that cast from some type ``source`` to another type ``target``, such that:

-  Both ``source`` and ``target`` are array types.
-  The element type of ``source`` is a transitive super type of the element type of ``target``.

This recipe is not too difficult to translate into a QL query:

.. code-block:: ql

   import java

   from CastExpr ce, Array source, Array target
   where source = ce.getExpr().getType() and
       target = ce.getType() and
       target.getElementType().(RefType).getASupertype+() = source.getElementType()
   select ce, "Potentially problematic array downcast."

➤ `See this in the query console <https://lgtm.com/query/666680038/>`__. Many projects return results for this query.

Note that by casting ``target.getElementType()`` to a ``RefType``, we eliminate all cases where the element type is a primitive type, that is, ``target`` is an array of primitive type: the problem we are looking for cannot arise in that case. Unlike in Java, a cast in QL never fails: if an expression cannot be cast to the desired type, it is simply excluded from the query results, which is exactly what we want.

Improvements
~~~~~~~~~~~~

Running this query on pre-Java 5 code often returns many false positive results arising from uses of the method ``Collection.toArray(T[])``, which converts a collection into an array of type ``T[]``.

In code that does not use generics, this method is often used in the following way:

.. code-block:: java

   List l = new ArrayList();
   // add some elements of type A to l
   A[] as = (A[])l.toArray(new A[0]);

Here, ``l`` has the raw type ``List``, so ``l.toArray`` has return type ``Object[]``, independent of the type of its argument array. Hence the cast goes from ``Object[]`` to ``A[]`` and will be flagged as problematic by our query, although at runtime this cast can never go wrong.

To identify these cases, we can create two QL classes that represent, respectively, the ``Collection.toArray`` class, and calls to this method or any method that overrides it:

.. code-block:: ql

   /** class representing java.util.Collection.toArray(T[]) */
   class CollectionToArray extends Method {
       CollectionToArray() {
           this.getDeclaringType().hasQualifiedName("java.util", "Collection") and
           this.hasName("toArray") and
           this.getNumberOfParameters() = 1
       }
   }

   /** class representing calls to java.util.Collection.toArray(T[]) */
   class CollectionToArrayCall extends MethodAccess {
       CollectionToArrayCall() {
           exists(CollectionToArray m |
               this.getMethod().getSourceDeclaration().overrides*(m)
           )
       }

       /** the call's actual return type, as determined from its argument */
       Array getActualReturnType() {
           result = this.getArgument(0).getType()
       }
   }

Notice the use of ``getSourceDeclaration`` and ``overrides`` in the constructor of ``CollectionToArrayCall``: we want to find calls to ``Collection.toArray`` and to any method that overrides it, as well as any parameterized instances of these methods. In our example above, for instance, the call ``l.toArray`` resolves to method ``toArray`` in the raw class ``ArrayList``. Its source declaration is method\ ``toArray`` in the generic class ``ArrayList``, which overrides ``AbstractCollection.toArray``, which in turn overrides ``Collection.toArray``.

Using these new classes we can extend our query to exclude calls to ``toArray`` on an argument of type ``A[]`` which are then cast to ``A[]``:

.. code-block:: ql

   import java

   // Insert the class definitions from above

   from CastExpr ce, Array source, Array target
   where source = ce.getExpr().getType() and
       target = ce.getType() and
       target.getElementType().(RefType).getASupertype+() = source.getElementType() and
       not ce.getExpr().(CollectionToArrayCall).getActualReturnType() = target
   select ce, "Potentially problematic array downcast."

➤ `See this in the query console <https://lgtm.com/query/668700471/>`__. Notice that fewer results are found by this improved query.

Example: Finding mismatched contains checks
-------------------------------------------

As another example, we develop a query that finds uses of ``Collection.contains`` where the type of the queried element is unrelated to the element type of the collection, thus guaranteeing that the test will always return ``false``.

For example, `Apache Zookeeper <http://zookeeper.apache.org/>`__ used to have a snippet of code similar to the following in class ``QuorumPeerConfig``:

.. code-block:: java

   Map<Object, Object> zkProp;

   // ...

   if (zkProp.entrySet().contains("dynamicConfigFile")){
       // ...
   }

Since ``zkProp`` is a map from ``Object`` to ``Object``, ``zkProp.entrySet`` returns a collection of type ``Set<Entry<Object, Object>>``. Such a set cannot possibly contain an element of type ``String``. (The code has since been fixed to use ``zkProp.containsKey``.)

In general, we want to find calls to ``Collection.contains`` (or any of its overriding methods in any parameterized instance of ``Collection``), such that the type ``E`` of collection elements and the type ``A`` of the argument to ``contains`` are unrelated, that is, they have no common subtype.

We start by creating a QL class that describes ``java.util.Collection``:

.. code-block:: ql

   class JavaUtilCollection extends GenericInterface {
       JavaUtilCollection() {
           this.hasQualifiedName("java.util", "Collection")
       }
   }

To make sure we have not mistyped anything, we can run a simple test query:

.. code-block:: ql

   from JavaUtilCollection juc
   select juc

This query should return precisely one result.

Next, we can create a QL class that describes ``java.util.Collection.contains``:

.. code-block:: ql

   class JavaUtilCollectionContains extends Method {
       JavaUtilCollectionContains() {
           this.getDeclaringType() instanceof JavaUtilCollection and
           this.hasStringSignature("contains(Object)")
       }
   }

Notice that we use ``hasStringSignature`` to check that:

-  The method in question has name ``contains``.
-  It has exactly one argument.
-  The type of the argument is ``Object``.

Alternatively, we could have implemented these three checks more verbosely using ``hasName``, ``getNumberOfParameters``, and ``getParameter(0).getType() instanceof TypeObject``.

As before, it is a good idea to test the new QL class by running a simple query to select all instances of ``JavaUtilCollectionContains``; again there should only be a single result.

Now we want to identify all calls to ``Collection.contains``, including any methods that override it, and considering all parameterized instances of ``Collection`` and its subclasses. That is, we are looking for method accesses where the source declaration of the invoked method (reflexively or transitively) overrides ``Collection.contains``. We encode this in a QL class ``JavaUtilCollectionContainsCall``:

.. code-block:: ql

   class JavaUtilCollectionContainsCall extends MethodAccess {
       JavaUtilCollectionContainsCall() {
           exists(JavaUtilCollectionContains jucc |
               this.getMethod().getSourceDeclaration().overrides*(jucc)
           )
       }
   }

This definition is slightly subtle, so you should run a short query to test that ``JavaUtilCollectionContainsCall`` correctly identifies calls to ``Collection.contains``.

For every call to ``contains``, we are interested in two things: the type of the argument, and the element type of the collection on which it is invoked. So we need to add two member predicates ``getArgumentType`` and ``getCollectionElementType`` to class ``JavaUtilCollectionContainsCall`` to compute this information.

The former is easy:

.. code-block:: ql

   Type getArgumentType() {
       result = this.getArgument(0).getType()
   }

For the latter, we proceed as follows:

-  Find the declaring type ``D`` of the ``contains`` method being invoked.
-  Find a (reflexive or transitive) super type ``S`` of ``D`` that is a parameterized instance of ``java.util.Collection``.
-  Return the (only) type argument of ``S``.

We encode this in QL as follows:

.. code-block:: ql

   Type getCollectionElementType() {
       exists(RefType D, ParameterizedInterface S |
           D = this.getMethod().getDeclaringType() and
           D.hasSupertype*(S) and S.getSourceDeclaration() instanceof JavaUtilCollection and
           result = S.getTypeArgument(0)
       )
   }

Having added these two member predicates to ``JavaUtilCollectionContainsCall``, we need to write a predicate that checks whether two given reference types have a common subtype:

.. code-block:: ql

   predicate haveCommonDescendant(RefType tp1, RefType tp2) {
       exists(RefType commondesc | commondesc.hasSupertype*(tp1) and commondesc.hasSupertype*(tp2))
   }

Now we are ready to write a first version of our query:

.. code-block:: ql

   import java

   // Insert the class definitions from above

   from JavaUtilCollectionContainsCall juccc, Type collEltType, Type argType
   where collEltType = juccc.getCollectionElementType() and argType = juccc.getArgumentType() and
       not haveCommonDescendant(collEltType, argType)
   select juccc, "Element type " + collEltType + " is incompatible with argument type " + argType

➤ `See this in the query console <https://lgtm.com/query/1505750556420/>`__.

Improvements
~~~~~~~~~~~~

For many programs, this query yields a large number of false positive results due to type variables and wild cards: if the collection element type is some type variable ``E`` and the argument type is ``String``, for example, QL will consider that the two have no common subtype, and our query will flag the call. An easy way to exclude such false positive results is to simply require that neither ``collEltType`` nor ``argType`` are instances of ``TypeVariable``.

Another source of false positives is autoboxing of primitive types: if, for example, the collection's element type is ``Integer`` and the argument is of type ``int``, predicate ``haveCommonDescendant`` will fail, since ``int`` is not a ``RefType``. Thus, our query should check that ``collEltType`` is not the boxed type of ``argType``.

Finally, ``null`` is special because its type (known as ``<nulltype>`` in QL) is compatible with every reference type, so we should exclude it from consideration.

Adding these three improvements, our final query becomes:

.. code-block:: ql

   import java

   // Insert the class definitions from above

   from JavaUtilCollectionContainsCall juccc, Type collEltType, Type argType
   where collEltType = juccc.getCollectionElementType() and argType = juccc.getArgumentType() and
       not haveCommonDescendant(collEltType, argType) and
       not collEltType instanceof TypeVariable and not argType instanceof TypeVariable and
       not collEltType = argType.(PrimitiveType).getBoxedType() and
       not argType.hasName("<nulltype>")
   select juccc, "Element type " + collEltType + " is incompatible with argument type " + argType

➤ `See the full query in the query console <https://lgtm.com/query/1505753056300/>`__.

What next?
----------

-  Take a look at some of the other tutorials: :doc:`Tutorial: Expressions and statements <expressions-statements>`, :doc:`Tutorial: Navigating the call graph <call-graph>`, :doc:`Tutorial: Annotations <annotations>`, :doc:`Tutorial: Javadoc <javadoc>`, :doc:`Tutorial: Working with source locations <source-locations>`.
-  Find out how specific classes in the AST are represented in the QL standard library for Java: :doc:`AST class reference <ast-class-reference>`.
-  Find out more about QL in the `QL language handbook <https://help.semmle.com/QL/ql-handbook/index.html>`__ and `QL language specification <https://help.semmle.com/QL/QLLanguageSpecification.html>`__.
