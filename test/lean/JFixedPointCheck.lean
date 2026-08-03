import JFixedPoint

example : JFixedPoint.contract JFixedPoint.«unit-obs» = 196884 := rfl
example : JFixedPoint.contract (JFixedPoint.stack 0) = 196884 := JFixedPoint.«fixed-0»
example : JFixedPoint.contract (JFixedPoint.stack 1) = 196884 := JFixedPoint.«fixed-1»
example : JFixedPoint.contract (JFixedPoint.stack 2) = 196884 := JFixedPoint.«fixed-2»
example : JFixedPoint.contract (JFixedPoint.stack 100) = 196884 := JFixedPoint.«fixed-100»
example :
    JFixedPoint.«contract-all» JFixedPoint.«tower-3» =
      [196884, 196884, 196884] := rfl
