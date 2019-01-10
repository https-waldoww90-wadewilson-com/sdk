// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:front_end/src/api_unstable/dart2js.dart'
    show operatorFromString;

import 'package:kernel/ast.dart' as ir;

import '../common.dart';
import '../common/names.dart';
import '../common_elements.dart';
import '../constants/expressions.dart';
import '../constants/values.dart';
import '../elements/entities.dart';
import '../elements/types.dart';
import '../ir/runtime_type_analysis.dart';
import '../ir/scope.dart';
import '../ir/static_type.dart';
import '../ir/impact.dart';
import '../ir/util.dart';
import '../js_backend/annotations.dart';
import '../js_backend/native_data.dart';
import '../options.dart';
import '../resolution/registry.dart' show ResolutionWorldImpactBuilder;
import '../universe/call_structure.dart';
import '../universe/feature.dart';
import '../universe/selector.dart';
import '../universe/use.dart';
import '../universe/world_builder.dart';
import 'element_map.dart';

class KernelImpactBuilder extends ImpactBuilder {
  final ResolutionWorldImpactBuilder impactBuilder;
  final KernelToElementMap elementMap;
  final DiagnosticReporter reporter;
  final CompilerOptions _options;
  final MemberEntity currentMember;
  final Set<PragmaAnnotation> _annotations;

  KernelImpactBuilder(this.elementMap, this.currentMember, this.reporter,
      this._options, VariableScopeModel variableScopeModel, this._annotations)
      : this.impactBuilder =
            new ResolutionWorldImpactBuilder('${currentMember}'),
        super(elementMap.typeEnvironment, elementMap.classHierarchy,
            variableScopeModel);

  CommonElements get commonElements => elementMap.commonElements;

  NativeBasicData get _nativeBasicData => elementMap.nativeBasicData;

  bool get useAsserts => _options.enableUserAssertions;

  bool get inferEffectivelyFinalVariableTypes =>
      !_annotations.contains(PragmaAnnotation.disableFinal);

  /// Add a checked-mode type use of [type] if it is not `dynamic`.
  DartType checkType(ir.DartType irType, TypeUseKind kind) {
    DartType type = elementMap.getDartType(irType);
    if (kind != null && !type.isDynamic) {
      switch (kind) {
        case TypeUseKind.PARAMETER_CHECK:
          impactBuilder.registerTypeUse(new TypeUse.parameterCheck(type));
          break;
        case TypeUseKind.IMPLICIT_CAST:
          impactBuilder.registerTypeUse(new TypeUse.implicitCast(type));
          break;
        default:
          throw new UnsupportedError("Unexpected type check kind: $kind");
      }
    }
    return type;
  }

  List<DartType> _getTypeArguments(ir.Arguments arguments) {
    if (arguments.types.isEmpty) return null;
    return arguments.types.map(elementMap.getDartType).toList();
  }

  /// Add checked-mode type use for the parameter type and constant for the
  /// default value of [parameter].
  @override
  void handleParameter(ir.VariableDeclaration parameter) {
    checkType(parameter.type, TypeUseKind.PARAMETER_CHECK);
  }

  /// Add checked-mode type use for parameter and return types, and add
  /// constants for default values.
  @override
  void handleSignature(ir.FunctionNode node) {
    for (ir.TypeParameter parameter in node.typeParameters) {
      checkType(parameter.bound, TypeUseKind.PARAMETER_CHECK);
    }
  }

  @override
  void handleField(ir.Field field) {
    checkType(field.type, TypeUseKind.PARAMETER_CHECK);
    if (field.initializer != null) {
      if (!field.isInstanceMember &&
          !field.isConst &&
          field.initializer is! ir.NullLiteral) {
        impactBuilder.registerFeature(Feature.LAZY_FIELD);
      }
    } else {
      impactBuilder.registerConstantLiteral(new NullConstantExpression());
    }

    if (field.isInstanceMember &&
        elementMap.isNativeClass(field.enclosingClass)) {
      MemberEntity member = elementMap.getMember(field);
      bool isJsInterop = _nativeBasicData.isJsInteropMember(member);
      impactBuilder.registerNativeData(elementMap
          .getNativeBehaviorForFieldLoad(field, isJsInterop: isJsInterop));
      impactBuilder
          .registerNativeData(elementMap.getNativeBehaviorForFieldStore(field));
    }
  }

  @override
  void handleConstructor(ir.Constructor constructor) {
    MemberEntity member = elementMap.getMember(constructor);
    if (constructor.isExternal && !commonElements.isForeignHelper(member)) {
      bool isJsInterop = _nativeBasicData.isJsInteropMember(member);
      impactBuilder.registerNativeData(elementMap
          .getNativeBehaviorForMethod(constructor, isJsInterop: isJsInterop));
    }
  }

  @override
  void registerSyncStar(ir.DartType elementType) {
    impactBuilder.registerFeature(Feature.SYNC_STAR);
    impactBuilder.registerStaticUse(new StaticUse.staticInvoke(
        commonElements.syncStarIterableFactory,
        const CallStructure.unnamed(1, 1),
        <DartType>[elementMap.getDartType(elementType)]));
  }

  @override
  void registerAsync(ir.DartType elementType) {
    impactBuilder.registerFeature(Feature.ASYNC);
    impactBuilder.registerStaticUse(new StaticUse.staticInvoke(
        commonElements.asyncAwaitCompleterFactory,
        const CallStructure.unnamed(0, 1),
        <DartType>[elementMap.getDartType(elementType)]));
  }

  @override
  void registerAsyncStar(ir.DartType elementType) {
    impactBuilder.registerFeature(Feature.ASYNC_STAR);
    impactBuilder.registerStaticUse(new StaticUse.staticInvoke(
        commonElements.asyncStarStreamControllerFactory,
        const CallStructure.unnamed(1, 1),
        <DartType>[elementMap.getDartType(elementType)]));
  }

  @override
  void handleProcedure(ir.Procedure procedure) {
    handleAsyncMarker(procedure.function);
    MemberEntity member = elementMap.getMember(procedure);
    if (procedure.isExternal && !commonElements.isForeignHelper(member)) {
      bool isJsInterop = _nativeBasicData.isJsInteropMember(member);
      impactBuilder.registerNativeData(elementMap
          .getNativeBehaviorForMethod(procedure, isJsInterop: isJsInterop));
    }
  }

  @override
  void registerIntLiteral(int value) {
    impactBuilder.registerConstantLiteral(
        new IntConstantExpression(new BigInt.from(value).toUnsigned(64)));
  }

  @override
  void registerDoubleLiteral(double value) {
    impactBuilder.registerConstantLiteral(new DoubleConstantExpression(value));
  }

  @override
  void registerBoolLiteral(bool value) {
    impactBuilder.registerConstantLiteral(new BoolConstantExpression(value));
  }

  @override
  void registerStringLiteral(String value) {
    impactBuilder.registerConstantLiteral(new StringConstantExpression(value));
  }

  @override
  void registerSymbolLiteral(String value) {
    impactBuilder.registerConstSymbolName(value);
  }

  @override
  void registerNullLiteral() {
    impactBuilder.registerConstantLiteral(new NullConstantExpression());
  }

  @override
  void registerListLiteral(ir.DartType elementType,
      {bool isConstant, bool isEmpty}) {
    impactBuilder.registerListLiteral(new ListLiteralUse(
        commonElements.listType(elementMap.getDartType(elementType)),
        isConstant: isConstant,
        isEmpty: isEmpty));
  }

  @override
  void registerMapLiteral(ir.DartType keyType, ir.DartType valueType,
      {bool isConstant, bool isEmpty}) {
    impactBuilder.registerMapLiteral(new MapLiteralUse(
        commonElements.mapType(
            elementMap.getDartType(keyType), elementMap.getDartType(valueType)),
        isConstant: isConstant,
        isEmpty: isEmpty));
  }

  @override
  void handleConstructorInvocation(ir.ConstructorInvocation node,
      ArgumentTypes argumentTypes, ir.DartType resultType) {
    handleNew(node, node.target, isConst: node.isConst);
  }

  void handleNew(ir.InvocationExpression node, ir.Member target,
      {bool isConst: false}) {
    ConstructorEntity constructor = elementMap.getConstructor(target);
    if (commonElements.isSymbolConstructor(constructor)) {
      impactBuilder.registerFeature(Feature.SYMBOL_CONSTRUCTOR);
    }

    if (target.isExternal &&
        constructor.isFromEnvironmentConstructor &&
        !isConst) {
      impactBuilder.registerFeature(Feature.THROW_UNSUPPORTED_ERROR);
      // We need to register the external constructor as live below, so don't
      // return here.
    }

    InterfaceType type = elementMap.createInterfaceType(
        target.enclosingClass, node.arguments.types);
    CallStructure callStructure = elementMap.getCallStructure(node.arguments);
    ImportEntity deferredImport = elementMap.getImport(getDeferredImport(node));
    impactBuilder.registerStaticUse(isConst
        ? new StaticUse.constConstructorInvoke(
            constructor, callStructure, type, deferredImport)
        : new StaticUse.typedConstructorInvoke(
            constructor, callStructure, type, deferredImport));
    if (type.typeArguments.any((DartType type) => !type.isDynamic)) {
      impactBuilder.registerFeature(Feature.TYPE_VARIABLE_BOUNDS_CHECK);
    }
    if (isConst && commonElements.isSymbolConstructor(constructor)) {
      ConstantValue value =
          elementMap.getConstantValue(node.arguments.positional.first);
      if (!value.isString) {
        // TODO(het): Get the actual span for the Symbol constructor argument
        reporter.reportErrorMessage(
            CURRENT_ELEMENT_SPANNABLE,
            MessageKind.STRING_EXPECTED,
            {'type': value.getType(elementMap.commonElements)});
        return;
      }
      StringConstantValue stringValue = value;
      impactBuilder.registerConstSymbolName(stringValue.stringValue);
    }
  }

  @override
  Null handleSuperInitializer(
      ir.SuperInitializer node, ArgumentTypes argumentTypes) {
    // TODO(johnniwinther): Maybe rewrite `node.target` to point to a
    // synthesized unnamed mixin constructor when needed. This would require us
    // to consider impact building a required pre-step for inference and
    // ssa-building.
    ConstructorEntity target =
        elementMap.getSuperConstructor(node.parent, node.target);
    impactBuilder.registerStaticUse(new StaticUse.superConstructorInvoke(
        target, elementMap.getCallStructure(node.arguments)));
  }

  void handleStaticInvocation(ir.StaticInvocation node,
      ArgumentTypes argumentTypes, ir.DartType returnType) {
    if (node.target.kind == ir.ProcedureKind.Factory) {
      // TODO(johnniwinther): We should not mark the type as instantiated but
      // rather follow the type arguments directly.
      //
      // Consider this:
      //
      //    abstract class A<T> {
      //      factory A.regular() => new B<T>();
      //      factory A.redirect() = B<T>;
      //    }
      //
      //    class B<T> implements A<T> {}
      //
      //    main() {
      //      print(new A<int>.regular() is B<int>);
      //      print(new A<String>.redirect() is B<String>);
      //    }
      //
      // To track that B is actually instantiated as B<int> and B<String> we
      // need to follow the type arguments passed to A.regular and A.redirect
      // to B. Currently, we only do this soundly if we register A<int> and
      // A<String> as instantiated. We should instead register that A.T is
      // instantiated as int and String.
      handleNew(node, node.target, isConst: node.isConst);
    } else {
      FunctionEntity target = elementMap.getMethod(node.target);
      List<DartType> typeArguments = _getTypeArguments(node.arguments);
      if (commonElements.isExtractTypeArguments(target)) {
        _handleExtractTypeArguments(node, target, typeArguments);
        return;
      }
      ImportEntity deferredImport =
          elementMap.getImport(getDeferredImport(node));
      impactBuilder.registerStaticUse(new StaticUse.staticInvoke(
          target,
          elementMap.getCallStructure(node.arguments),
          typeArguments,
          deferredImport));
    }
    switch (elementMap.getForeignKind(node)) {
      case ForeignKind.JS:
        impactBuilder
            .registerNativeData(elementMap.getNativeBehaviorForJsCall(node));
        break;
      case ForeignKind.JS_BUILTIN:
        impactBuilder.registerNativeData(
            elementMap.getNativeBehaviorForJsBuiltinCall(node));
        break;
      case ForeignKind.JS_EMBEDDED_GLOBAL:
        impactBuilder.registerNativeData(
            elementMap.getNativeBehaviorForJsEmbeddedGlobalCall(node));
        break;
      case ForeignKind.JS_INTERCEPTOR_CONSTANT:
        InterfaceType type =
            elementMap.getInterfaceTypeForJsInterceptorCall(node);
        if (type != null) {
          impactBuilder.registerTypeUse(new TypeUse.instantiation(type));
        }
        break;
      case ForeignKind.NONE:
        break;
    }
  }

  void _handleExtractTypeArguments(ir.StaticInvocation node,
      FunctionEntity target, List<DartType> typeArguments) {
    // extractTypeArguments<Map>(obj, fn) has additional impacts:
    //
    //   1. All classes implementing Map need to carry type arguments (similar
    //      to checking `o is Map<K, V>`).
    //
    //   2. There is an invocation of fn with some number of type arguments.
    //
    impactBuilder.registerStaticUse(new StaticUse.staticInvoke(
        target, elementMap.getCallStructure(node.arguments), typeArguments));

    if (typeArguments.length != 1) return;
    DartType matchedType = typeArguments.first;

    if (matchedType is! InterfaceType) return;
    InterfaceType interfaceType = matchedType;
    ClassEntity cls = interfaceType.element;
    InterfaceType thisType = elementMap.elementEnvironment.getThisType(cls);

    impactBuilder.registerTypeUse(new TypeUse.isCheck(thisType));

    Selector selector = new Selector.callClosure(
        0, const <String>[], thisType.typeArguments.length);
    impactBuilder.registerDynamicUse(
        new ConstrainedDynamicUse(selector, null, thisType.typeArguments));
  }

  @override
  void registerStaticTearOff(
      ir.Procedure procedure, ir.LibraryDependency import) {
    impactBuilder.registerStaticUse(new StaticUse.staticTearOff(
        elementMap.getMethod(procedure), elementMap.getImport(import)));
  }

  @override
  void registerStaticGet(ir.Member member, ir.LibraryDependency import) {
    impactBuilder.registerStaticUse(new StaticUse.staticGet(
        elementMap.getMember(member), elementMap.getImport(import)));
  }

  @override
  void registerStaticSet(ir.Member member, ir.LibraryDependency import) {
    impactBuilder.registerStaticUse(new StaticUse.staticSet(
        elementMap.getMember(member), elementMap.getImport(import)));
  }

  void handleSuperInvocation(ir.Name name, ir.Node arguments) {
    FunctionEntity method =
        elementMap.getSuperMember(currentMember, name, setter: false);
    List<DartType> typeArguments = _getTypeArguments(arguments);
    if (method != null) {
      impactBuilder.registerStaticUse(new StaticUse.superInvoke(
          method, elementMap.getCallStructure(arguments), typeArguments));
    } else {
      impactBuilder.registerStaticUse(new StaticUse.superInvoke(
          elementMap.getSuperNoSuchMethod(currentMember.enclosingClass),
          CallStructure.ONE_ARG));
      impactBuilder.registerFeature(Feature.SUPER_NO_SUCH_METHOD);
    }
  }

  @override
  void handleDirectMethodInvocation(
      ir.DirectMethodInvocation node,
      ir.DartType receiverType,
      ArgumentTypes argumentTypes,
      ir.DartType returnType) {
    List<DartType> typeArguments = _getTypeArguments(node.arguments);
    MemberEntity member = elementMap.getMember(node.target);
    // TODO(johnniwinther): Restrict the dynamic use to only match the known
    // target.
    // TODO(johnniwinther): Restrict this to subclasses?
    Object constraint = new StrongModeConstraint(
        commonElements, _nativeBasicData, member.enclosingClass);
    impactBuilder.registerDynamicUse(new ConstrainedDynamicUse(
        new Selector.call(
            member.memberName, elementMap.getCallStructure(node.arguments)),
        constraint,
        typeArguments));
  }

  @override
  void handleSuperMethodInvocation(ir.SuperMethodInvocation node,
      ArgumentTypes argumentTypes, ir.DartType returnType) {
    // TODO(johnniwinther): Should we support this or always use the
    // [MixinFullResolution] transformer?
    handleSuperInvocation(node.name, node.arguments);
  }

  void handleSuperGet(ir.Name name, ir.Member target) {
    MemberEntity member =
        elementMap.getSuperMember(currentMember, name, setter: false);
    if (member != null) {
      if (member.isFunction) {
        impactBuilder.registerStaticUse(new StaticUse.superTearOff(member));
      } else {
        impactBuilder.registerStaticUse(new StaticUse.superGet(member));
      }
    } else {
      impactBuilder.registerStaticUse(new StaticUse.superInvoke(
          elementMap.getSuperNoSuchMethod(currentMember.enclosingClass),
          CallStructure.ONE_ARG));
      impactBuilder.registerFeature(Feature.SUPER_NO_SUCH_METHOD);
    }
  }

  @override
  void handleDirectPropertyGet(ir.DirectPropertyGet node,
      ir.DartType receiverType, ir.DartType resultType) {
    // TODO(johnniwinther): Restrict the dynamic use to only match the known
    // target.
    impactBuilder.registerDynamicUse(new DynamicUse(
        new Selector.getter(elementMap.getMember(node.target).memberName)));
  }

  @override
  void handleSuperPropertyGet(
      ir.SuperPropertyGet node, ir.DartType resultType) {
    handleSuperGet(node.name, node.interfaceTarget);
  }

  void handleSuperSet(ir.Name name, ir.Node target, ir.Node value) {
    MemberEntity member =
        elementMap.getSuperMember(currentMember, name, setter: true);
    if (member != null) {
      if (member.isField) {
        impactBuilder.registerStaticUse(new StaticUse.superFieldSet(member));
      } else {
        impactBuilder.registerStaticUse(new StaticUse.superSetterSet(member));
      }
    } else {
      impactBuilder.registerStaticUse(new StaticUse.superInvoke(
          elementMap.getSuperNoSuchMethod(currentMember.enclosingClass),
          CallStructure.ONE_ARG));
      impactBuilder.registerFeature(Feature.SUPER_NO_SUCH_METHOD);
    }
  }

  @override
  void handleDirectPropertySet(ir.DirectPropertySet node,
      ir.DartType receiverType, ir.DartType valueType) {
    // TODO(johnniwinther): Restrict the dynamic use to only match the known
    // target.
    impactBuilder.registerDynamicUse(new DynamicUse(
        new Selector.setter(elementMap.getMember(node.target).memberName)));
  }

  @override
  void handleSuperPropertySet(ir.SuperPropertySet node, ir.DartType valueType) {
    handleSuperSet(node.name, node.interfaceTarget, node.value);
  }

  @override
  void handleMethodInvocation(
      ir.MethodInvocation node,
      ir.DartType receiverType,
      ArgumentTypes argumentTypes,
      ir.DartType returnType) {
    Selector selector = elementMap.getSelector(node);
    List<DartType> typeArguments = _getTypeArguments(node.arguments);
    ir.Expression receiver = node.receiver;
    if (receiver is ir.VariableGet &&
        receiver.variable.isFinal &&
        receiver.variable.parent is ir.FunctionDeclaration) {
      Local localFunction =
          elementMap.getLocalFunction(receiver.variable.parent);
      // Invocation of a local function. No need for dynamic use, but
      // we need to track the type arguments.
      impactBuilder.registerStaticUse(new StaticUse.closureCall(
          localFunction, selector.callStructure, typeArguments));
      // TODO(johnniwinther): Yet, alas, we need the dynamic use for now. Remove
      // this when kernel adds an `isFunctionCall` flag to
      // [ir.MethodInvocation].
      impactBuilder.registerDynamicUse(
          new ConstrainedDynamicUse(selector, null, typeArguments));
    } else {
      ClassRelation relation = receiver is ir.ThisExpression
          ? ClassRelation.thisExpression
          : ClassRelation.subtype;
      DartType receiverDartType = elementMap.getDartType(receiverType);
      Object constraint;
      if (receiverDartType is InterfaceType) {
        constraint = new StrongModeConstraint(commonElements, _nativeBasicData,
            receiverDartType.element, relation);
      }
      ir.Member interfaceTarget = node.interfaceTarget;
      if (interfaceTarget == null) {
        // TODO(johnniwinther): Avoid treating a known function call as a
        // dynamic call when CFE provides a way to distinguish the two.
        impactBuilder.registerDynamicUse(
            new ConstrainedDynamicUse(selector, constraint, typeArguments));
        if (operatorFromString(node.name.name) == null &&
            receiverDartType.isDynamic) {
          // We might implicitly call a getter that returns a function.
          impactBuilder.registerDynamicUse(new ConstrainedDynamicUse(
              selector.toCallSelector(), null, typeArguments));
        }
      } else {
        if (interfaceTarget is ir.Field ||
            interfaceTarget is ir.Procedure &&
                interfaceTarget.kind == ir.ProcedureKind.Getter) {
          impactBuilder.registerDynamicUse(
              new ConstrainedDynamicUse(selector, constraint, typeArguments));
          // An `o.foo()` invocation is (potentially) an `o.foo.call()`
          // invocation.
          Object getterConstraint;
          if (interfaceTarget != null) {
            DartType receiverType =
                elementMap.getDartType(interfaceTarget.getterType);
            if (receiverType is InterfaceType) {
              getterConstraint = new StrongModeConstraint(
                  commonElements, _nativeBasicData, receiverType.element);
            }
          }

          impactBuilder.registerDynamicUse(new ConstrainedDynamicUse(
              selector.toCallSelector(), getterConstraint, typeArguments));
        } else {
          impactBuilder.registerDynamicUse(
              new ConstrainedDynamicUse(selector, constraint, typeArguments));
        }
      }
    }
  }

  @override
  void handlePropertyGet(
      ir.PropertyGet node, ir.DartType receiverType, ir.DartType resultType) {
    Object constraint;
    DartType receiverDartType = elementMap.getDartType(receiverType);
    if (receiverDartType is InterfaceType) {
      ClassRelation relation = node.receiver is ir.ThisExpression
          ? ClassRelation.thisExpression
          : ClassRelation.subtype;
      constraint = new StrongModeConstraint(
          commonElements, _nativeBasicData, receiverDartType.element, relation);
    }
    impactBuilder.registerDynamicUse(new ConstrainedDynamicUse(
        new Selector.getter(elementMap.getName(node.name)),
        constraint, const <DartType>[]));

    if (node.name.name == Identifiers.runtimeType_) {
      RuntimeTypeUseData data = computeRuntimeTypeUse(node);
      DartType receiverType = elementMap.getStaticType(data.receiver);
      DartType argumentType = data.argument == null
          ? null
          : elementMap.getStaticType(data.argument);

      if (_options.omitImplicitChecks) {
        switch (data.kind) {
          case RuntimeTypeUseKind.string:
            if (!_options.laxRuntimeTypeToString) {
              if (receiverType == commonElements.objectType) {
                reporter.reportHintMessage(computeSourceSpanFromTreeNode(node),
                    MessageKind.RUNTIME_TYPE_TO_STRING_OBJECT);
              } else {
                reporter.reportHintMessage(
                    computeSourceSpanFromTreeNode(node),
                    MessageKind.RUNTIME_TYPE_TO_STRING_SUBTYPE,
                    {'receiverType': '${receiverType}.'});
              }
            }
            break;
          case RuntimeTypeUseKind.equals:
          case RuntimeTypeUseKind.unknown:
            break;
        }
      }
      impactBuilder.registerRuntimeTypeUse(
          new RuntimeTypeUse(data.kind, receiverType, argumentType));
    }
  }

  @override
  void handlePropertySet(
      ir.PropertySet node, ir.DartType receiverType, ir.DartType valueType) {
    Object constraint;
    DartType receiverDartType = elementMap.getDartType(receiverType);
    if (receiverDartType is InterfaceType) {
      ClassRelation relation = node.receiver is ir.ThisExpression
          ? ClassRelation.thisExpression
          : ClassRelation.subtype;
      constraint = new StrongModeConstraint(
          commonElements, _nativeBasicData, receiverDartType.element, relation);
    }
    impactBuilder.registerDynamicUse(new ConstrainedDynamicUse(
        new Selector.setter(elementMap.getName(node.name)),
        constraint, const <DartType>[]));
  }

  @override
  void registerAssert({bool withMessage}) {
    impactBuilder.registerFeature(
        withMessage ? Feature.ASSERT_WITH_MESSAGE : Feature.ASSERT);
  }

  @override
  void registerGenericInstantiation(
      ir.FunctionType expressionType, List<ir.DartType> typeArguments) {
    // TODO(johnniwinther): Track which arities are used in instantiation.
    impactBuilder.registerInstantiation(new GenericInstantiation(
        elementMap.getDartType(expressionType),
        typeArguments.map(elementMap.getDartType).toList()));
  }

  @override
  void registerStringConcatenation() {
    impactBuilder.registerFeature(Feature.STRING_INTERPOLATION);
    impactBuilder.registerFeature(Feature.STRING_JUXTAPOSITION);
  }

  @override
  void registerLocalFunction(ir.TreeNode node) {
    Local function = elementMap.getLocalFunction(node);
    impactBuilder.registerStaticUse(new StaticUse.closure(function));
  }

  @override
  void registerLocalWithoutInitializer() {
    impactBuilder.registerFeature(Feature.LOCAL_WITHOUT_INITIALIZER);
  }

  @override
  void registerIsCheck(ir.DartType type) {
    impactBuilder
        .registerTypeUse(new TypeUse.isCheck(elementMap.getDartType(type)));
  }

  @override
  void registerImplicitCast(ir.DartType type) {
    impactBuilder.registerTypeUse(
        new TypeUse.implicitCast(elementMap.getDartType(type)));
  }

  @override
  void registerAsCast(ir.DartType type) {
    impactBuilder
        .registerTypeUse(new TypeUse.asCast(elementMap.getDartType(type)));
  }

  @override
  @override
  void registerThrow() {
    impactBuilder.registerFeature(Feature.THROW_EXPRESSION);
  }

  void registerSyncForIn(ir.DartType iterableType) {
    // TODO(johnniwinther): Use receiver constraints for the dynamic uses in
    // strong mode.
    impactBuilder.registerFeature(Feature.SYNC_FOR_IN);
    impactBuilder.registerDynamicUse(new DynamicUse(Selectors.iterator));
    impactBuilder.registerDynamicUse(new DynamicUse(Selectors.current));
    impactBuilder.registerDynamicUse(new DynamicUse(Selectors.moveNext));
  }

  void registerAsyncForIn(ir.DartType iterableType) {
    // TODO(johnniwinther): Use receiver constraints for the dynamic uses in
    // strong mode.
    impactBuilder.registerFeature(Feature.ASYNC_FOR_IN);
    impactBuilder.registerDynamicUse(new DynamicUse(Selectors.cancel));
    impactBuilder.registerDynamicUse(new DynamicUse(Selectors.current));
    impactBuilder.registerDynamicUse(new DynamicUse(Selectors.moveNext));
  }

  void registerCatch() {
    impactBuilder.registerFeature(Feature.CATCH_STATEMENT);
  }

  void registerStackTrace() {
    impactBuilder.registerFeature(Feature.STACK_TRACE_IN_CATCH);
  }

  void registerCatchType(ir.DartType type) {
    impactBuilder
        .registerTypeUse(new TypeUse.catchType(elementMap.getDartType(type)));
  }

  @override
  void registerTypeLiteral(ir.DartType type, ir.LibraryDependency import) {
    ImportEntity deferredImport = elementMap.getImport(import);
    impactBuilder.registerTypeUse(
        new TypeUse.typeLiteral(elementMap.getDartType(type), deferredImport));
    if (type is ir.FunctionType) {
      assert(type.typedef != null);
      // TODO(johnniwinther): Can we avoid the typedef type altogether?
      // We need to ensure that the typedef is live.
      elementMap.getTypedefType(type.typedef);
    }
  }

  @override
  void registerFieldInitializer(ir.Field node) {
    impactBuilder
        .registerStaticUse(new StaticUse.fieldInit(elementMap.getField(node)));
  }

  @override
  void registerRedirectingInitializer(
      ir.Constructor constructor, ir.Arguments arguments) {
    ConstructorEntity target = elementMap.getConstructor(constructor);
    impactBuilder.registerStaticUse(new StaticUse.superConstructorInvoke(
        target, elementMap.getCallStructure(arguments)));
  }

  @override
  void registerLoadLibrary() {
    impactBuilder.registerStaticUse(new StaticUse.staticInvoke(
        commonElements.loadDeferredLibrary, CallStructure.ONE_ARG));
    impactBuilder.registerFeature(Feature.LOAD_LIBRARY);
  }

  @override
  void handleSwitchStatement(ir.SwitchStatement node) {
    // TODO(32557): Remove this when issue 32557 is fixed.
    ir.TreeNode firstCase;
    DartType firstCaseType;
    DiagnosticMessage error;
    List<DiagnosticMessage> infos = <DiagnosticMessage>[];

    bool overridesEquals(InterfaceType type) {
      if (type == commonElements.symbolImplementationType) {
        // Treat symbol constants as if Symbol doesn't override `==`.
        return false;
      }
      ClassEntity cls = type.element;
      while (cls != null) {
        MemberEntity member =
            elementMap.elementEnvironment.lookupClassMember(cls, '==');
        if (member.isAbstract) {
          cls = elementMap.elementEnvironment.getSuperClass(cls);
        } else {
          return member.enclosingClass != commonElements.objectClass;
        }
      }
      return false;
    }

    for (ir.SwitchCase switchCase in node.cases) {
      for (ir.Expression expression in switchCase.expressions) {
        ConstantValue value = elementMap.getConstantValue(expression);
        DartType type = value.getType(elementMap.commonElements);
        if (firstCaseType == null) {
          firstCase = expression;
          firstCaseType = type;

          // We only report the bad type on the first class element. All others
          // get a "type differs" error.
          if (type == commonElements.doubleType) {
            reporter.reportErrorMessage(
                computeSourceSpanFromTreeNode(expression),
                MessageKind.SWITCH_CASE_VALUE_OVERRIDES_EQUALS,
                {'type': "double"});
          } else if (type == commonElements.functionType) {
            reporter.reportErrorMessage(computeSourceSpanFromTreeNode(node),
                MessageKind.SWITCH_CASE_FORBIDDEN, {'type': "Function"});
          } else if (value.isObject &&
              type != commonElements.typeLiteralType &&
              overridesEquals(type)) {
            reporter.reportErrorMessage(
                computeSourceSpanFromTreeNode(firstCase),
                MessageKind.SWITCH_CASE_VALUE_OVERRIDES_EQUALS,
                {'type': type});
          }
        } else {
          if (type != firstCaseType) {
            if (error == null) {
              error = reporter.createMessage(
                  computeSourceSpanFromTreeNode(node),
                  MessageKind.SWITCH_CASE_TYPES_NOT_EQUAL,
                  {'type': firstCaseType});
              infos.add(reporter.createMessage(
                  computeSourceSpanFromTreeNode(firstCase),
                  MessageKind.SWITCH_CASE_TYPES_NOT_EQUAL_CASE,
                  {'type': firstCaseType}));
            }
            infos.add(reporter.createMessage(
                computeSourceSpanFromTreeNode(expression),
                MessageKind.SWITCH_CASE_TYPES_NOT_EQUAL_CASE,
                {'type': type}));
          }
        }
      }
    }
    if (error != null) {
      reporter.reportError(error, infos);
    }
  }
}