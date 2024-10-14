private import powershell
private import semmle.code.powershell.Cfg
private import DataFlowPrivate
private import DataFlowPublic
private import semmle.code.powershell.typetracking.internal.TypeTrackingImpl
private import codeql.util.Boolean
private import codeql.util.Unit

newtype TReturnKind = TNormalReturnKind()

/**
 * Gets a node that can read the value returned from `call` with return kind
 * `kind`.
 */
OutNode getAnOutNode(DataFlowCall call, ReturnKind kind) { call = result.getCall(kind) }

/**
 * A return kind. A return kind describes how a value can be returned
 * from a callable.
 */
abstract class ReturnKind extends TReturnKind {
  /** Gets a textual representation of this position. */
  abstract string toString();
}

/**
 * A value returned from a callable using a `return` statement or an expression
 * body, that is, a "normal" return.
 */
class NormalReturnKind extends ReturnKind, TNormalReturnKind {
  override string toString() { result = "return" }
}

/** A callable defined in library code, identified by a unique string. */
abstract class LibraryCallable extends string {
  bindingset[this]
  LibraryCallable() { any() }

  /** Gets a call to this library callable. */
  Call getACall() { none() }
}

/**
 * A callable. This includes callables from source code, as well as callables
 * defined in library code.
 */
class DataFlowCallable extends TDataFlowCallable {
  /**
   * Gets the underlying CFG scope, if any.
   *
   * This is usually a `Callable`, but can also be a `Toplevel` file.
   */
  CfgScope asCfgScope() { this = TCfgScope(result) }

  /** Gets the underlying library callable, if any. */
  LibraryCallable asLibraryCallable() { this = TLibraryCallable(result) }

  /** Gets a textual representation of this callable. */
  string toString() { result = [this.asCfgScope().toString(), this.asLibraryCallable()] }

  /** Gets the location of this callable. */
  Location getLocation() {
    result = this.asCfgScope().getLocation()
    or
    this instanceof TLibraryCallable and
    result instanceof EmptyLocation
  }

  /** Gets a best-effort total ordering. */
  int totalorder() { none() }
}

/**
 * A call. This includes calls from source code, as well as call(back)s
 * inside library callables with a flow summary.
 */
abstract class DataFlowCall extends TDataFlowCall {
  /** Gets the enclosing callable. */
  abstract DataFlowCallable getEnclosingCallable();

  /** Gets the underlying source code call, if any. */
  abstract CfgNodes::CallCfgNode asCall();

  /** Gets a textual representation of this call. */
  abstract string toString();

  /** Gets the location of this call. */
  abstract Location getLocation();

  DataFlowCallable getARuntimeTarget() { none() }

  ArgumentNode getAnArgumentNode() { none() }

  /** Gets a best-effort total ordering. */
  int totalorder() { none() }

  /**
   * Holds if this element is at the specified location.
   * The location spans column `startcolumn` of line `startline` to
   * column `endcolumn` of line `endline` in file `filepath`.
   * For more information, see
   * [Locations](https://codeql.github.com/docs/writing-codeql-queries/providing-locations-in-codeql-queries).
   */
  predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    this.getLocation().hasLocationInfo(filepath, startline, startcolumn, endline, endcolumn)
  }
}

class NormalCall extends DataFlowCall, TNormalCall {
  private CfgNodes::CallCfgNode c;

  NormalCall() { this = TNormalCall(c) }

  override CfgNodes::CallCfgNode asCall() { result = c }

  override DataFlowCallable getEnclosingCallable() { result = TCfgScope(c.getScope()) }

  override string toString() { result = c.toString() }

  override Location getLocation() { result = c.getLocation() }
}

private predicate localFlowStep(Node nodeFrom, Node nodeTo, StepSummary summary) {
  localFlowStepTypeTracker(nodeFrom, nodeTo) and
  summary.toString() = "level"
}

private module TrackInstanceInput implements CallGraphConstruction::InputSig {
  private predicate start0(Node start, string typename, boolean exact) {
    start.(ObjectCreationNode).getObjectCreationNode().getConstructedTypeName() = typename and
    exact = true
    or
    start.asExpr().(CfgNodes::ExprNodes::TypeNameCfgNode).getTypeName() = typename and
    exact = true
  }

  newtype State = additional MkState(string typename, Boolean exact) { start0(_, typename, exact) }

  predicate start(Node start, State state) {
    exists(string typename, boolean exact |
      state = MkState(typename, exact) and
      start0(start, typename, exact)
    )
  }

  pragma[nomagic]
  predicate stepNoCall(Node nodeFrom, Node nodeTo, StepSummary summary) {
    smallStepNoCall(nodeFrom, nodeTo, summary)
    or
    localFlowStep(nodeFrom, nodeTo, summary)
  }

  predicate stepCall(Node nodeFrom, Node nodeTo, StepSummary summary) {
    smallStepCall(nodeFrom, nodeTo, summary)
  }

  class StateProj = Unit;

  Unit stateProj(State state) { exists(state) and exists(result) }

  predicate filter(Node n, Unit u) { none() }
}

private predicate qualifiedCall(CfgNodes::CallCfgNode call, Node receiver, string method) {
  call.getQualifier() = receiver.asExpr() and
  call.getName() = method
}

Node trackInstance(string typename, boolean exact) {
  result =
    CallGraphConstruction::Make<TrackInstanceInput>::track(TrackInstanceInput::MkState(typename,
        exact))
}

private CfgScope getTargetInstance(CfgNodes::CallCfgNode call) {
  // TODO: Also match argument/parameter types
  exists(Node receiver, string method, string typename, Type t |
    qualifiedCall(call, receiver, method) and
    receiver = trackInstance(typename, _) and
    t.getName() = typename
  |
    if method = "new"
    then result = t.getAConstructor().getBody()
    else result = t.getMethod(method).getBody()
  )
}

/**
 * A unit class for adding additional call steps.
 *
 * Extend this class to add additional call steps to the data flow graph.
 */
class AdditionalCallTarget extends Unit {
  /**
   * Gets a viable target for `call`.
   */
  abstract DataFlowCallable viableTarget(CfgNodes::CallCfgNode call);
}

cached
private module Cached {
  cached
  newtype TDataFlowCallable =
    TCfgScope(CfgScope scope) or
    TLibraryCallable(LibraryCallable callable)

  cached
  newtype TDataFlowCall = TNormalCall(CfgNodes::CallCfgNode c)

  /** Gets a viable run-time target for the call `call`. */
  cached
  DataFlowCallable viableCallable(DataFlowCall call) {
    result.asCfgScope() = getTargetInstance(call.asCall())
    or
    result = any(AdditionalCallTarget t).viableTarget(call.asCall())
  }

  cached
  CfgScope getTarget(DataFlowCall call) { result = viableCallable(call).asCfgScope() }

  cached
  newtype TArgumentPosition =
    TThisArgumentPosition() or
    TKeywordArgumentPosition(string name) { name = any(Argument p).getName() } or
    TPositionalArgumentPosition(int pos, NamedSet ns) {
      exists(CfgNodes::CallCfgNode call |
        call = ns.getABindingCall() and
        exists(call.getArgument(pos))
      )
    } or
    TPipelineArgumentPosition()

  cached
  newtype TParameterPosition =
    TThisParameterPosition() or
    TKeywordParameter(string name) { name = any(Argument p).getName() } or
    TPositionalParameter(int pos, NamedSet ns) {
      exists(CfgNodes::CallCfgNode call |
        call = ns.getABindingCall() and
        exists(call.getArgument(pos))
      )
    } or
    TPipelineParameter()
}

import Cached

/** A parameter position. */
class ParameterPosition extends TParameterPosition {
  /** Holds if this position represents a `this` parameter. */
  predicate isThis() { this = TThisParameterPosition() }

  /**
   * Holds if this position represents a positional parameter at position `pos`
   * with function is called with exactly the named parameters from the set `ns`
   */
  predicate isPositional(int pos, NamedSet ns) { this = TPositionalParameter(pos, ns) }

  /** Holds if this parameter is a keyword parameter with `name`. */
  predicate isKeyword(string name) { this = TKeywordParameter(name) }

  predicate isPipeline() { this = TPipelineParameter() }

  /** Gets a textual representation of this position. */
  string toString() {
    this.isThis() and result = "this"
    or
    exists(int pos, NamedSet ns |
      this.isPositional(pos, ns) and result = "pos(" + pos + ", " + ns.toString() + ")"
    )
    or
    exists(string name | this.isKeyword(name) and result = "kw(" + name + ")")
    or
    this.isPipeline() and result = "pipeline"
  }
}

/** An argument position. */
class ArgumentPosition extends TArgumentPosition {
  /** Holds if this position represents a `this` argument. */
  predicate isThis() { this = TThisArgumentPosition() }

  /** Holds if this position represents a positional argument at position `pos`. */
  predicate isPositional(int pos, NamedSet ns) { this = TPositionalArgumentPosition(pos, ns) }

  predicate isKeyword(string name) { this = TKeywordArgumentPosition(name) }

  predicate isPipeline() { this = TPipelineArgumentPosition() }

  /** Gets a textual representation of this position. */
  string toString() {
    this.isThis() and result = "this"
    or
    exists(int pos, NamedSet ns |
      this.isPositional(pos, ns) and result = "pos(" + pos + ", " + ns.toString() + ")"
    )
    or
    exists(string name | this.isKeyword(name) and result = "kw(" + name + ")")
    or
    this.isPipeline() and result = "pipeline"
  }
}

/** Holds if arguments at position `apos` match parameters at position `ppos`. */
pragma[nomagic]
predicate parameterMatch(ParameterPosition ppos, ArgumentPosition apos) {
  ppos.isThis() and apos.isThis()
  or
  exists(string name |
    ppos.isKeyword(name) and
    apos.isKeyword(name)
  )
  or
  exists(int pos, NamedSet ns |
    ppos.isPositional(pos, ns) and
    apos.isPositional(pos, ns)
  )
  or
  ppos.isPipeline() and apos.isPipeline()
}
