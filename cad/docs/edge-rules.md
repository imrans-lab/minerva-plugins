# Geometric edge selection

Use geometric rules with the existing batch fillet/chamfer commands:

```text
beam = cube(20)
fillet beam, edges(beam, parallel=[0,0,1], expected=4), r=1
chamfer beam, edges(beam, face_normal=[0,0,1], outer=true), d=0.25
```

Filters combine with AND. `parallel` selects straight edges in either direction
along the vector. `face_normal` selects boundaries of planar faces whose outward
normal points in the specified direction. `outer=true` requires `face_normal`
and excludes inner boundary loops of those faces; it does not infer a universal
"outside" for a whole solid. Scaled straight splines and planar spline surfaces
are recognized geometrically.

`above_z` and `below_z` bound the **whole edge**, inclusively, in model millimetres.
`tolerance` defaults to 0.000001 mm; `angle_deg` defaults to 0.1 degrees. Optional
`expected` refuses a changed match count. Empty selections always fail.

A stored selection belongs to that exact shape. After filleting, chamfering or
replacing the shape, select again. Legacy numeric edge IDs and lists still work,
but their IDs remain specific to one evaluation/topology. Rules resolve before
one kernel operation; they do not create persistent topology names.
