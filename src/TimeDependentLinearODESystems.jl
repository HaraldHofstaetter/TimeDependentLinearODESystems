module TimeDependentLinearODESystems

using LinearAlgebra

export TimeDependentMatrixState, TimeDependentSchroedingerMatrixState
export TimeDependentMatrix, TimeDependentSchroedingerMatrix
export CF2, CF2g4, CF4, CF4g6, CF4o, CF4oH, CF6, CF6n, CF6ng8 
export CF7, CF8, CF8C, CF8AF,  CF10, DoPri45, Tsit45, Magnus4
export SchemeEstimatorPair
export load_example
export EquidistantTimeStepper, local_orders, local_orders_est
export AdaptiveTimeStepper, EquidistantCorrectedTimeStepper
export global_orders, global_orders_corr

include("expmv.jl")


"""
Object representing matrix `B` coming from `A(t)` for concrete t.

**This is not a state vector!**

For derived type `T` One must define:
 - `LinearAlgebra.size(H::T, dim::Int)`: dimensions of matrix
 - `LinearAlgebra.eltype(H::T)`: scalar type (Float64)
 - `LinearAlgebra.issymmetric(H::T)`: true iff matrix is symmetric
 - `LinearAlgebra.ishermitian(H::T)`: true iff matrix is hermitian
 - `LinearAlgebra.checksquare(H::T)`: exception if matrix is not square 
 - `LinearAlgebra.mul!(Y, H::T, B)`: performs `Y = H*B`
"""
abstract type TimeDependentMatrixState end

"""
Object representing matrix `B` coming from `H(t)` for concrete t.

**This is not a state vector!**
"""
abstract type TimeDependentSchroedingerMatrixState <: TimeDependentMatrixState end

"""
Object representing time-dependent matrix `A(t)`.

Given `A::TimeDependentMatrix`, one can do `B=A(t)` to obtain an object
of type `B::TimeDependentMatrixState`, which represents the matrix `A(t)`
evaluated at time `t`.

This is used to solve a ODE of the form  `dv(t)/dt = A(t) v(t)`.
"""
abstract type TimeDependentMatrix end

"""
Object representing time-dependent Hamiltonian `H(t)`.

This is used to solve a ODE of the form  `i dv(t)/dt = H(t) v(t)`.
"""
abstract type TimeDependentSchroedingerMatrix <: TimeDependentMatrix end


import Base.*
function *(A::TimeDependentMatrixState, B) 
    Y = similar(B)
    mul!(Y, A, B)
    Y
end

mul1!(Y, A::TimeDependentMatrixState, B) = mul!(Y, A, B)
function mul1!(Y, A::TimeDependentSchroedingerMatrixState, B) 
    mul!(Y, A, B)
    Y[:] *= -1im
end

function expmv1!(y, dt, A::TimeDependentMatrixState, x, tol, m, wsp) 
   if tol==0
       y[:] = exp(dt*full(A))*x
   else
       expmv!(y, dt, A, x, tol=tol, m=m, wsp=wsp) 
   end
end

function expmv1!(y, dt, A::TimeDependentSchroedingerMatrixState, x, tol, m, wsp) 
   if tol==0
       y[:] = exp(-1im*dt*full(A))*x
   else
       expmv!(y, -1im*dt, A, x, tol=tol, m=m, wsp=wsp) 
   end
end



load_example(name::String) = include(string(dirname(@__FILE__),"/../examples/",name))

abstract type Scheme end

mutable struct SchemeEstimatorPair <: Scheme
    scheme::Scheme
    estimator::Scheme
    substeps::Int64
    SchemeEstimatorPair(scheme::Scheme, estimator::Scheme; substeps::Int=1) = new(scheme, estimator, substeps)
end

get_order(scheme::SchemeEstimatorPair) = get_order(scheme.scheme)
number_of_exponentials(scheme::SchemeEstimatorPair) = number_of_exponentials(scheme.scheme)
get_lwsp(H, scheme::SchemeEstimatorPair, m::Integer) = max(get_lwsp(H, scheme.scheme, m), get_lwsp(H, scheme.estimator, m))

function step_estimated!(psi::Array{Complex{Float64},1}, psi_est::Array{Complex{Float64},1},
                 H::TimeDependentMatrix, 
                 t::Real, dt::Real,
                 scheme::SchemeEstimatorPair,
                 wsp::Vector{Vector{Complex{Float64}}}; 
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
    copyto!(psi_est, psi)
    step!(psi, H, t, dt, scheme.scheme, wsp, expmv_tol=expmv_tol, expmv_m=expmv_m)
    dt1 = dt/scheme.substeps
    for k=1:scheme.substeps
        step!(psi_est, H, t, dt1, scheme.estimator, wsp, expmv_tol=expmv_tol, expmv_m=expmv_m)
        t += dt1
    end
    psi_est[:] = psi[:] - psi_est[:]
end




"""
Parameters of integration scheme.

A single time step is then computed from this formula, where `X(t)` is the matrix
`-i H(t)` and `A` and `c` are the parameters of the scheme.

    psi(t+dt) = product(exp(sum(A[j,k] * X(t + c[k]*dt) for k in 1:K)
                        for j in J:-1:1) * psi(t)

**Note:** A is now not the matrix in the ODE, and c are not the coefficients of
the linear combination for evaluating H.

`p` is the order of the scheme.
"""
mutable struct CommutatorFreeScheme <:Scheme
    A::Array{Float64,2}
    c::Array{Float64,1}
    p::Int
    symmetrized_defect::Bool
    trapezoidal_rule::Bool
    modified_Gamma::Bool
    adjoint_based::Bool
    function CommutatorFreeScheme(
            A::Array{Float64,2},
            c::Array{Float64,1},
            p::Int;
            symmetrized_defect::Bool=false,
            trapezoidal_rule::Bool=false,
            modified_Gamma::Bool=false,
            adjoint_based::Bool=false,
            )
        new(A,c,p,
        symmetrized_defect,
        trapezoidal_rule,
        modified_Gamma,
        adjoint_based)
    end
end

function (CF::CommutatorFreeScheme)(;
    symmetrized_defect::Bool=CF.symmetrized_defect,
    trapezoidal_rule::Bool=CF.trapezoidal_rule,
    modified_Gamma::Bool=CF.modified_Gamma,
    adjoint_based::Bool=CF.adjoint_based)
    CommutatorFreeScheme(CF.A, CF.c, CF.p,
        symmetrized_defect=symmetrized_defect,
        trapezoidal_rule=trapezoidal_rule,
        modified_Gamma=modified_Gamma,
        adjoint_based=adjoint_based)
end

get_order(scheme::CommutatorFreeScheme) = scheme.p
number_of_exponentials(scheme::CommutatorFreeScheme) = size(scheme.A, 1)
get_lwsp(H, scheme::CommutatorFreeScheme, m::Integer) = m+2 

"""Exponential midpoint rule"""
CF2 = CommutatorFreeScheme( ones(1,1), [1/2], 2 )

CF2g4 = CommutatorFreeScheme( [1/2 1/2], [1/2-sqrt(3)/6, 1/2+sqrt(3)/6], 2 )

CF4 = CommutatorFreeScheme(
    [1/4+sqrt(3)/6 1/4-sqrt(3)/6
     1/4-sqrt(3)/6 1/4+sqrt(3)/6],
    [1/2-sqrt(3)/6, 1/2+sqrt(3)/6],
     4)

CF4g6 = CommutatorFreeScheme(
     [(2*sqrt(15)+5)/36   2/9  (-2*sqrt(15)+5)/36
      (-2*sqrt(15)+5)/36  2/9  (2*sqrt(15)+5)/36],
     [1/2-sqrt(15)/10, 1/2, 1/2+sqrt(15)/10],
     4)

CF4o = CommutatorFreeScheme(
    [37/240+10/87*sqrt(5/3) -1/30  37/240-10/87*sqrt(5/3)
     -11/360                23/45  -11/360
     37/240-10/87*sqrt(5/3) -1/30  37/240+10/87*sqrt(5/3)],
     [1/2-sqrt(15)/10, 1/2, 1/2+sqrt(15)/10],
     4)

CF4oH = CommutatorFreeScheme(
#optimized with respect to LEM with equal weight:
#[ 0.311314623379755386999882845054  -0.027985859584027834823234100810  0.007787203484903714984134658507
# -0.041324049086881324206239725785   0.500416163612500114090912646066 -0.041324049086881324206239725788
#  0.0077872034849037149841346585064 -0.027985859584027834823234100810  0.311314623379755386999882845055],    
#
# optimized with respect to scaled LEM with weights 
# [A1,[A1,[A1,A2]]]: 1, [A2,[A1,A2]]: 0.031, [A1,[A1,A3]]: 0.077, [A2,A3]: 0.00013
[  0.302146842308616954258187683416  -0.030742768872036394116279742324  0.004851603407498684079562131338
  -0.029220667938337860559972036973   0.505929982188517232677003929089 -0.029220667938337860559972036973
   0.004851603407498684079562131337  -0.030742768872036394116279742324  0.302146842308616954258187683417],
  [1/2-sqrt(15)/10, 1/2, 1/2+sqrt(15)/10],
     4)


CF6 = TimeDependentLinearODESystems.CommutatorFreeScheme(
[-0.20052856057448226894  1.8713900774428756530 -0.59100909048596250164
  0.32223594293373734804 -1.6491678552206534307  0.74707948590448520033 
  0.74707948590448520027 -1.6491678552206534307  0.32223594293373734809 
 -0.59100909048596250159  1.8713900774428756530 -0.20052856057448226900],
[1/2-sqrt(15)/10, 1/2, 1/2+sqrt(15)/10],
     6)

CF6g8 = TimeDependentLinearODESystems.CommutatorFreeScheme(
[-0.34314400153702789748 1.1195678797143181223 0.91838304591063001179 -0.61495449770548935422
0.41814779815983290968 -0.96538391082227167806 -0.74649443737140338475 0.71387812365141127071
0.71387812365141127066 -0.74649443737140338471 -0.96538391082227167811 0.41814779815983290974
-0.61495449770548935417 0.91838304591063001175 1.1195678797143181224 -0.34314400153702789754],
     [-sqrt(1/140*(2*sqrt(30)+15))+1/2, 
    -sqrt(1/140*(-2*sqrt(30)+15))+1/2,
     sqrt(1/140*(-2*sqrt(30)+15))+1/2, 
     sqrt(1/140*(2*sqrt(30)+15))+1/2],
   6)     

CF6old = CommutatorFreeScheme(
  [ 0.2158389969757678 -0.0767179645915514  0.0208789676157837
   -0.0808977963208530 -0.1787472175371576  0.0322633664310473 
    0.1806284600558301  0.4776874043509313 -0.0909342169797981
   -0.0909342169797981  0.4776874043509313  0.1806284600558301
    0.0322633664310473 -0.1787472175371576 -0.0808977963208530 
    0.0208789676157837 -0.0767179645915514  0.2158389969757678],
  [1/2-sqrt(15)/10, 1/2, 1/2+sqrt(15)/10],
  6)

CF6n = CommutatorFreeScheme(
  [ 7.9124225942889763e-01 -8.0400755305553218e-02  1.2765293626634554e-02
   -4.8931475164583259e-01  5.4170980027798808e-02 -1.2069823881924156e-02
   -2.9025638294289255e-02  5.0138457552775674e-01 -2.5145341733509552e-02
    4.8759082890019896e-03 -3.0710355805557892e-02  3.0222764976657693e-01],
  [1/2-sqrt(15)/10, 1/2, 1/2+sqrt(15)/10],
  6)

CF6ng8 = CommutatorFreeScheme(
[5.89464201605815655765303416672229380e-01 2.43830015772764437289913379731814221e-01 -1.57259787655929092496086012361705682e-01 4.75723680273279690817865828307895985e-02; -3.65105740082651034389439866942092769e-01 -1.47548276150151315750289379302899394e-01 9.83396340552589170241119484898018497e-02 -3.28992133224145061662174359910648657e-02; -6.86020666155581903549750505993981876e-02 2.89858731629633708796424619465199666e-01 2.91857952484170189124028989070900103e-01 -6.59010219982877682836438241904462939e-02; 1.81710276611204976656434754802610403e-02 -6.00678938209737590225805945051140074e-02 9.31347785477730576614131001900042084e-02 2.25155289862101234054606651961721100e-01],
   [-sqrt(1/140*(2*sqrt(30)+15))+1/2, 
    -sqrt(1/140*(-2*sqrt(30)+15))+1/2,
     sqrt(1/140*(-2*sqrt(30)+15))+1/2, 
     sqrt(1/140*(2*sqrt(30)+15))+1/2],
   6)
  

CF7 = CommutatorFreeScheme(
 [ 2.05862188450411892209e-01    1.69508382914682544509e-01   -1.02088008415028059851e-01    3.04554010755044437431e-02 
  -5.74532495795307023280e-02    2.34286861311879288330e-01    3.32946059487076984706e-01   -7.03703697036401378340e-02
  -8.93040281749440468751e-03    2.71488489365780259156e-02   -2.95144169823456538040e-02   -1.51311830884601959206e-01
   5.52299810755465569835e-01   -3.64425287556240176808e+00    2.53660580449381888484e+00   -6.61436528542997675116e-01
  -5.38241659087501080427e-01    3.60578285850975236760e+00   -2.50685041783117850901e+00    6.51947409253201845106e-01 
   2.03907348473756540850e-02   -6.64014986792173869631e-02    9.49735566789294244299e-02    3.74643341371260411994e-01],  
   [-sqrt(1/140*(2*sqrt(30)+15))+1/2, 
    -sqrt(1/140*(-2*sqrt(30)+15))+1/2,
     sqrt(1/140*(-2*sqrt(30)+15))+1/2, 
     sqrt(1/140*(2*sqrt(30)+15))+1/2],
   7)


CF8 = CommutatorFreeScheme(
 [ 1.84808462624313039047e-01   -2.07206621202004201439e-02    5.02711867953985524846e-03   -1.02882825365674947238e-03
  -2.34494788701189042407e-02    4.21259009948623260268e-01   -4.74878986332597661320e-02    9.04478813619618482626e-03
   4.46203609236170079455e-02   -2.12369356865717369483e-01    5.69989517802253965907e-01    6.02984678266997385471e-03
  -4.93752515735367769884e-02    2.32989476865882554115e-01   -6.22614628245849008467e-01    3.27752279924315371495e-03
   3.27752279924315371495e-03   -6.22614628245849008467e-01    2.32989476865882554115e-01   -4.93752515735367769884e-02
   6.02984678266997385471e-03    5.69989517802253965907e-01   -2.12369356865717369483e-01    4.46203609236170079455e-02
   9.04478813619618482626e-03   -4.74878986332597661320e-02    4.21259009948623260268e-01   -2.34494788701189042407e-02
  -1.02882825365674947238e-03    5.02711867953985524846e-03   -2.07206621202004201439e-02    1.84808462624313039047e-01],
   [-sqrt(1/140*(2*sqrt(30)+15))+1/2, 
    -sqrt(1/140*(-2*sqrt(30)+15))+1/2,
     sqrt(1/140*(-2*sqrt(30)+15))+1/2, 
     sqrt(1/140*(2*sqrt(30)+15))+1/2],
   8)


CF8C = CommutatorFreeScheme( # from CASC paper
 [-1.232611007291861933e+00  1.381999278877963415e-01 -3.352921035850962622e-02  6.861942424401394962e-03 
   1.452637092757343214e+00 -1.632549976033022450e-01  3.986114827352239259e-02 -8.211316003097062961e-03 
  -1.783965547974815151e-02 -8.850494961553933912e-02 -1.299159096777419811e-02  4.448254906109529464e-03 
  -2.982838328015747208e-02  4.530735723950198008e-01 -6.781322579940055086e-03 -1.529505464262590422e-03 
  -1.529505464262590422e-03 -6.781322579940055086e-03  4.530735723950198008e-01 -2.982838328015747208e-02 
   4.448254906109529464e-03 -1.299159096777419811e-02 -8.850494961553933912e-02 -1.783965547974815151e-02 
  -8.211316003097062961e-03  3.986114827352239259e-02 -1.632549976033022450e-01  1.452637092757343214e+00 
   6.861942424401394962e-03 -3.352921035850962622e-02  1.381999278877963415e-01 -1.232611007291861933e+00],
   [-sqrt(1/140*(2*sqrt(30)+15))+1/2, 
    -sqrt(1/140*(-2*sqrt(30)+15))+1/2,
     sqrt(1/140*(-2*sqrt(30)+15))+1/2, 
     sqrt(1/140*(2*sqrt(30)+15))+1/2],
   8)
   

CF8AF = CommutatorFreeScheme(
 [ 1.87122040358115390530e-01   -2.17649338120833602438e-02    5.52892003021124482393e-03   -1.17049553231009501581e-03
   1.20274380119388885065e-03    4.12125752973891079564e-01   -4.12733647828949079769e-02    7.36567552381537106608e-03
   1.35345551498985132129e-01   -5.22856505688516843294e-01    8.04624511929284544063e-01    5.23457489042977401203e-02
  -1.28946403255047767209e-01    4.98263615941272492752e-01   -7.66539274112930211564e-01   -5.10038659643654002820e-02
  -1.13857707205616619581e-02   -1.56116196769613328288e-01   -1.38617787803146844186e-01    1.21952821870042290581e-02
  -2.91430842323998986020e-02    2.52697839525799205662e-01    2.52697839525799205662e-01   -2.91430842323998986020e-02
   1.21952821870042290581e-02   -1.38617787803146844186e-01   -1.56116196769613328288e-01   -1.13857707205616619581e-02
  -5.10038659643654002820e-02   -7.66539274112930211564e-01    4.98263615941272492752e-01   -1.28946403255047767209e-01
   5.23457489042977401203e-02    8.04624511929284544063e-01   -5.22856505688516843294e-01    1.35345551498985132129e-01
   7.36567552381537106608e-03   -4.12733647828949079769e-02    4.12125752973891079564e-01    1.20274380119388885065e-03
  -1.17049553231009501581e-03    5.52892003021124482393e-03   -2.17649338120833602438e-02    1.87122040358115390530e-01],
   [-sqrt(1/140*(2*sqrt(30)+15))+1/2, 
    -sqrt(1/140*(-2*sqrt(30)+15))+1/2,
     sqrt(1/140*(-2*sqrt(30)+15))+1/2, 
     sqrt(1/140*(2*sqrt(30)+15))+1/2],
   8)

   
CF10 = CommutatorFreeScheme(
 [1.257519487460748505e-01 -1.865909914245271482e-02  6.733376258605780510e-03 -2.718352784202390925e-03  7.068483735775850990e-04
 -2.895851111122071992e-03  2.923981849411676845e-01 -4.296189672654135889e-02  1.490123420460316949e-02 -3.808961956414262732e-03
  3.578233942230071908e-02 -2.008488760890393015e-01  6.682006550293361043e-01  8.920336627376998761e-02 -3.910578669555082511e-02
 -1.944671056480696889e-02  1.108002059111070326e-01 -3.720332832453305167e-01 -4.180370067214972631e-02  1.501200997424843587e-02
 -6.498700096451508075e-03 -6.581426937488461349e-03  2.350498736569961365e-01 -8.781176304922676745e-02 -3.978644052337576376e-03
  3.032747599105825582e-02 -3.672352541131558981e-02 -4.341457984155596505e-01  1.431037387565488689e-01 -1.472822613175338694e-02
  1.444710249189639879e-02  9.808293294138223008e-02 -4.072013249310684334e-01  1.240141313609900441e-02  1.992268959805941013e-02
 -3.658914067788396192e-03 -1.244739113166053859e-01  4.885806205957841604e-01 -1.956085512514405479e-03 -2.936517739289611528e-02
 -2.936517739289611528e-02 -1.956085512514405479e-03  4.885806205957841604e-01 -1.244739113166053859e-01 -3.658914067788396192e-03
  1.992268959805941013e-02  1.240141313609900441e-02 -4.072013249310684334e-01  9.808293294138223008e-02  1.444710249189639879e-02
 -1.472822613175338694e-02  1.431037387565488689e-01 -4.341457984155596505e-01 -3.672352541131558981e-02  3.032747599105825582e-02
 -3.978644052337576376e-03 -8.781176304922676745e-02  2.350498736569961365e-01 -6.581426937488461349e-03 -6.498700096451508075e-03
  1.501200997424843587e-02 -4.180370067214972631e-02 -3.720332832453305167e-01  1.108002059111070326e-01 -1.944671056480696889e-02
 -3.910578669555082511e-02  8.920336627376998761e-02  6.682006550293361043e-01 -2.008488760890393015e-01  3.578233942230071908e-02
 -3.808961956414262732e-03  1.490123420460316949e-02 -4.296189672654135889e-02  2.923981849411676845e-01 -2.895851111122071992e-03
  7.068483735775850990e-04 -2.718352784202390925e-03  6.733376258605780510e-03 -1.865909914245271482e-02  1.257519487460748505e-01], 
  ([-sqrt(5+2*sqrt(10/7))/3,
   -sqrt(5-2*sqrt(10/7))/3,
   0.0,
   +sqrt(5-2*sqrt(10/7))/3,
   +sqrt(5+2*sqrt(10/7))/3] .+1)/2,
   10) 




function step!(psi::Array{Complex{Float64},1}, H::TimeDependentMatrix, 
               t::Real, dt::Real, scheme::CommutatorFreeScheme,
               wsp::Vector{Vector{Complex{Float64}}}; 
               expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
    tt = t .+ dt*scheme.c
    for j=1:number_of_exponentials(scheme)
        H1 = H(tt, scheme.A[j,:])
        expmv1!(psi, dt, H1, psi, expmv_tol, expmv_m, wsp)
    end
end  

function Gamma!(r::Vector{Complex{Float64}},
                H::TimeDependentMatrixState, Hd::TimeDependentMatrixState,
                u::Vector{Complex{Float64}}, p::Int, dt::Float64, 
                s1::Vector{Complex{Float64}}, s2::Vector{Complex{Float64}},
                s1a::Vector{Complex{Float64}}, s2a::Vector{Complex{Float64}};
                modified_Gamma::Bool=false)
    if p>6
        error("p<=6 expected")
    end
    f1 = dt
    f2 = dt^2/2
    f3 = dt^3/6
    f4 = dt^4/24
    f5 = dt^5/120  
    f6 = dt^6/720
    if modified_Gamma
        if p==2
            p = 3
            f3 = dt^3/4
        elseif p==4
            p = 5
            f5 = dt^5/144
        end
    end
    #s2=B*u
    mul1!(s2, H, u)
    r[:] = s2[:] 
    if p>=1
        #s1=A*u
        mul1!(s1, Hd, u)
        r[:] += f1*s1[:] 
    end
    if p>=2
        #s1=B*s1=BAu
        mul1!(s1a, H, s1)
        r[:] += f2*s1a[:] 
    end
    if p>=3
        #s1=B*s1=BBAu
        mul1!(s1, H, s1a)
        r[:] += f3*s1[:] 
    end
    if p>=4
        #s1=B*s1=BBBAu
        mul1!(s1a, H, s1)
        r[:] += f4*s1a[:] 
    end
    if p>=5
        #s1=B*s1=BBBBAu
        mul1!(s1, H, s1a)
        r[:] += f5*s1[:] 
    end
    if p>=6
        #s1=B*s1=BBBBBAu
        mul1!(s1a, H, s1)
        r[:] += f6*s1a[:] 
    end

    if p>=2
        #s1=A*s2=ABu
        mul1!(s1, Hd, s2)
        r[:] -= f2*s1[:] 
    end
    if p>=3
        #s1=B*s1=BABu
        mul1!(s1a, H, s1)
        r[:] -= (2*f3)*s1a[:] 
    end
    if p>=4
        #s1=B*s1=BBABu
        mul1!(s1, H, s1a)
        r[:] -= (3*f4)*s1[:] 
    end
    if p>=5
        #s1=B*s1=BBBABu
        mul1!(s1a, H, s1)
        r[:] -= (4*f5)*s1a[:] 
    end
    if p>=6
        #s1=B*s1=BBBBABu
        mul1!(s1, H, s1a)
        r[:] -= (5*f6)*s1[:] 
    end

    if p>=3
        #s2=B*s2=BBu
        mul1!(s2a, H, s2)
        #s1=A*s2=ABBu
        mul1!(s1, Hd, s2a)
        r[:] += f3*s1
    end
    if p>=4
        #s1=B*s1=BABBu
        mul1!(s1a, H, s1)
        r[:] += (3*f4)*s1a
    end
    if p>=5
        #s1=B*s1=BBABBu
        mul1!(s1, H, s1a)
        r[:] += (6*f5)*s1
    end
    if p>=6
        #s1=B*s1=BBBABBu
        mul1!(s1a, H, s1)
        r[:] += (10*f6)*s1a
    end

    if p>=4
        #s2=B*s2=BBBu
        mul1!(s2, H, s2a)
        #s1=A*s2=ABBBu
        mul1!(s1, Hd, s2)
        r[:] -= f4*s1
    end
    if p>=5
        #s1=B*s1=BABBBu
        mul1!(s1a, H, s1)
        r[:] -= (4*f5)*s1a
    end
    if p>=6
        #s1=B*s1=BBABBBu
        mul1!(s1, H, s1a)
        r[:] -= (10*f6)*s1
    end

    if p>=5
        #s2=B*s2=BBBBu
        mul1!(s2a, H, s2)
        #s1=A*s2=ABBBBu
        mul1!(s1, Hd, s2a)
        r[:] += f5*s1
    end
    if p>=6
        #s1=B*s1=BABBBBu
        mul1!(s1a, H, s1)
        r[:] += (5*f6)*s1a
    end

    if p>=6
        #s2=B*s2=BBBBBu
        mul1!(s2, H, s2a)
        #s1=A*s2=ABBBBBu
        mul1!(s1, Hd, s2)
        r[:] -= f6*s1
    end
end

function CC!(r::Vector{Complex{Float64}},
             H::TimeDependentMatrixState, Hd::TimeDependentMatrixState,
             u::Vector{Complex{Float64}}, sign::Int, dt::Float64, 
             s::Vector{Complex{Float64}}, s1::Vector{Complex{Float64}})
    mul1!(s, Hd, u)
    r[:] = 0.5*dt*s[:]
    mul1!(s1, H, s)
    r[:] += (sign*dt^2/12)*s1
    mul1!(s, H, u)
    r[:] += 0.5*s[:]
    mul1!(s1, Hd, s)
    r[:] -= (sign*dt^2/12)*s1
end



function step_estimated_CF2_trapezoidal_rule!(psi::Array{Complex{Float64},1}, psi_est::Array{Complex{Float64},1},
                 H::TimeDependentMatrix, 
                 t::Real, dt::Real,
                 wsp::Vector{Vector{Complex{Float64}}}; 
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
    n = size(H, 2)
    s = wsp[1]

    H1d = H(t+0.5*dt, compute_derivative=true)
    mul1!(psi_est, H1d, psi)
    psi_est[:] *= 0.25*dt

    H1 = H(t+0.5*dt)
    expmv1!(psi, dt, H1, psi, expmv_tol, expmv_m, wsp)
    expmv1!(psi_est, dt, H1, psi_est, expmv_tol, expmv_m, wsp)

    H1 = H(t+0.5*dt)
    mul1!(s, H1, psi)
    psi_est[:] += s[:]

    H1 = H(t+dt)
    mul1!(s, H1, psi)
    psi_est[:] -= s[:]

    H1d = H(t+0.5*dt, compute_derivative=true)
    mul1!(s, H1d, psi)
    psi_est[:] += 0.25*dt*s[:]

    psi_est[:] *= dt/3
end



function step_estimated_CF2_symm_def!(psi::Array{Complex{Float64},1}, psi_est::Array{Complex{Float64},1},
                 H::TimeDependentMatrix, 
                 t::Real, dt::Real,
                 wsp::Vector{Vector{Complex{Float64}}}; 
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))

    n = size(H, 2)
    s = wsp[1]

    H1 = H(t)
    mul1!(psi_est, H1, psi)
    psi_est[:] *= -0.5

    H1 = H(t+0.5*dt)
    expmv1!(psi, dt, H1, psi, expmv_tol, expmv_m, wsp)
    expmv1!(psi_est, dt, H1, psi_est, expmv_tol, expmv_m, wsp)
    
    H1 = H(t+0.5*dt)
    mul1!(s, H1, psi)
    psi_est[:] += s[:]

    H1 = H(t+dt)
    mul1!(s, H1, psi)
    s[:] *= 0.5
    psi_est[:] -= s[:]
    
    psi_est[:] *= dt/3
end


function step_estimated_adjoint_based!(psi::Array{Complex{Float64},1}, psi_est::Array{Complex{Float64},1},
                 H::TimeDependentMatrix, 
                 t::Real, dt::Real,
                 scheme::CommutatorFreeScheme,
                 wsp::Vector{Vector{Complex{Float64}}}; 
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
    tt1 = t .+ dt*scheme.c
    tt2 = t .+ dt*(1.0 .- scheme.c)
    psi_est[:] = psi[:]
    J = number_of_exponentials(scheme)
    for j=1:J
        H1 = H(tt1, scheme.A[j,:])
        H2 = H(tt2, scheme.A[J+1-j,:])
        expmv1!(psi, dt, H1, psi, expmv_tol, expmv_m, wsp)
        expmv1!(psi_est, dt, H2, psi_est, expmv_tol, expmv_m, wsp)
    end
    psi_est[:] -= psi[:]
    psi_est[:] *= -0.5
end


function step_estimated!(psi::Array{Complex{Float64},1}, psi_est::Array{Complex{Float64},1},
                 H::TimeDependentMatrix, 
                 t::Real, dt::Real,
                 scheme::CommutatorFreeScheme,
                 wsp::Vector{Vector{Complex{Float64}}}; 
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
    if scheme.c == [0.5] #midpoint rule
        if scheme.symmetrized_defect  
            step_estimated_CF2_symm_def!(psi, psi_est, H, t, dt, wsp, expmv_tol=expmv_tol, expmv_m=expmv_m)
            return
        elseif scheme.trapezoidal_rule 
           step_estimated_CF2_trapezoidal_rule!(psi, psi_est, H, t, dt, wsp, expmv_tol=expmv_tol, expmv_m=expmv_m)
           return
       end
    end
    if scheme.adjoint_based
        if !isodd(get_order(scheme))
            error("For adjoint_based=true order of scheme has to be odd")
        end
        step_estimated_adjoint_based!(psi, psi_est, H, t, dt, scheme, wsp, expmv_tol=expmv_tol, expmv_m=expmv_m)
        return
    end
    n = size(H, 2)
    s = wsp[1]
    s1 = wsp[2]
    s2 = wsp[3]
    s1a = wsp[4]
    s2a = wsp[5]

    tt = t .+ dt*scheme.c

    if scheme.symmetrized_defect
        H1 = H(t)
        mul1!(psi_est, H1, psi)
        psi_est[:] *= -0.5
    else
        psi_est[:] .= 0.0
    end

    J = number_of_exponentials(scheme)

    for j=1:J
        H1 = H(tt, scheme.A[j,:])
        if scheme.symmetrized_defect
            H1d = H(tt, (scheme.c .- 0.5).*scheme.A[j,:], compute_derivative=true)
        else
            H1d = H(tt, scheme.c.*scheme.A[j,:], compute_derivative=true)
        end
        if scheme.trapezoidal_rule 
            CC!(s, H1, H1d, psi, -1, dt, s1, s2)
            psi_est[:] += s[:]
        end

        expmv1!(psi, dt, H1, psi, expmv_tol, expmv_m, wsp)
        if scheme.symmetrized_defect || scheme.trapezoidal_rule || j>1
            expmv1!(psi_est, dt, H1, psi_est, expmv_tol, expmv_m, wsp)
        end
    
        if scheme.trapezoidal_rule
            CC!(s, H1, H1d, psi, +1, dt, s1, s2)
        else
            Gamma!(s, H1, H1d, psi, scheme.p, dt, s1, s2, s1a, s2a, modified_Gamma=scheme.modified_Gamma)
        end
        psi_est[:] += s[:]
    end
   
    H1 = H(t+dt)
    mul1!(s, H1, psi)
    if scheme.symmetrized_defect
        s[:] *= 0.5
    end
    psi_est[:] -= s[:]

    psi_est[:] *= dt/(scheme.p+1)

end



mutable struct EmbeddedRungeKuttaScheme <:Scheme
    A::Array{Float64,2}
    c::Array{Float64,1}
    b::Array{Float64,1}
    p::Int
    function EmbeddedRungeKuttaScheme(
            A::Array{Float64,2},
            c::Array{Float64,1},
            b::Array{Float64,1},
            p::Int
            )
        new(A,c,b,p)
    end
end

DoPri45 = EmbeddedRungeKuttaScheme(
          [0.0         0.0        0.0         0.0      0.0          0.0     0.0
           1/5         0.0        0.0         0.0      0.0          0.0     0.0
           3/40        9/40       0.0         0.0      0.0          0.0     0.0
           44/45      -56/15      32/9        0.0      0.0          0.0     0.0
           19372/6561 -25360/2187 64448/6561 -212/729  0.0          0.0     0.0
           9017/3168  -355/33     46732/5247  49/176  -5103/18656   0.0     0.0
           35/384      0.0        500/1113    125/192 -2187/6784    11/84   0.0],
          [0.0, 1/5, 3/10, 4/5, 8/9, 1.0, 1.0],
          [5179/57600, 0.0,        7571/16695,  393/640, -92097/339200, 187/2100, 1/40],
          4
        )

# see 
#   Ch.Tsitouras: Runge–Kutta pairs of order 5(4) satisfying only the first column simplifying assumption
#   Computers & Mathematics with Applications 62 (2011), 770-775
   Tsit45 = EmbeddedRungeKuttaScheme(
          [0.0                  0.0                 0.0                0.0                   0.0                   0.0                 0.0
           0.161                0.0                 0.0                0.0                   0.0                   0.0                 0.0
          -0.008480655492356992 0.3354806554923570  0.0                0.0                   0.0                   0.0                 0.0
           2.8971530571054944   -6.359448489975075  4.362295432869581  0.0                   0.0                   0.0                 0.0
           5.32586482843926     -11.74888356406283  7.495539342889836  -0.09249506636175525  0.0                   0.0                 0.0
           5.8614554429464      -12.92096931784711  8.159367898576159  -0.07158497328140100  -0.02826905039406838  0.0                 0.0
           0.09646076681806523  0.01                0.4798896504144996 1.379008574103742     -3.290069515436081    2.324710524099774   0.0],
          [0.0,                 0.161,              0.327,             0.9,                  0.9800255409045097,   1.0,                1.0],
          [0.001780011052226,   0.000816434459657, -0.007880878010262, 0.144711007173263, -0.58235716545255,  0.458082105929187, -1/66]+
          [0.09646076681806523, 0.01 ,             0.4798896504144996, 1.379008574103742, -3.290069515436081, 2.324710524099774 , 0.0],  
          4
         )
        

#TODO: consider case b!=A[end,:]

get_lwsp(H, scheme::EmbeddedRungeKuttaScheme, m::Integer) = length(scheme.c)+1
get_order(scheme::EmbeddedRungeKuttaScheme) = scheme.p

function step_estimated!(psi::Array{Complex{Float64},1}, psi_est::Array{Complex{Float64},1},
                 H::TimeDependentMatrix, 
                 t::Real, dt::Real,
                 scheme::EmbeddedRungeKuttaScheme,
                 wsp::Vector{Vector{Complex{Float64}}}; 
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
      nstages = length(scheme.c)
      K = wsp 
      s = K[nstages+1]
      for l=1:nstages
          s[:] = psi
          for j=1:l-1
              if scheme.A[l,j]!=0.0
                  s[:] += (dt*scheme.A[l,j])*K[j][:]
              end
          end
          H1 = H(t+scheme.c[l]*dt)
          mul1!(K[l], H1, s)
      end
      psi_est[:] = s[:]
      for j=1:nstages
          if scheme.b[j]!=0.0
              psi[:] += (dt*scheme.b[j])*K[j][:]
          end
      end
      psi_est[:] = psi[:] - psi_est[:]
      # TODO: K[7] can be reused as K[1] for the next step (FSAL, first same as last)
end


mutable struct MagnusScheme <: Scheme 
    p::Int
    symmetrized_defect::Bool
    trapezoidal_rule::Bool
    modified_Gamma::Bool
    function MagnusScheme(
            p::Int;
            symmetrized_defect::Bool=false,
            trapezoidal_rule::Bool=false,
            modified_Gamma::Bool=false,
            )
        new(p,
        symmetrized_defect,
        trapezoidal_rule,
        modified_Gamma)
    end
end

function (M::MagnusScheme)(;
    symmetrized_defect::Bool=M.symmetrized_defect,
    trapezoidal_rule::Bool=M.trapezoidal_rule,
    modified_Gamma::Bool=M.modified_Gamma)
    MagnusScheme(M.p,
        symmetrized_defect=symmetrized_defect,
        trapezoidal_rule=trapezoidal_rule,
        modified_Gamma=modified_Gamma)
end

Magnus4 = MagnusScheme(4)


get_lwsp(H, scheme::MagnusScheme, m::Integer) = m+4 
get_order(M::MagnusScheme) = M.p 
number_of_exponentials(::MagnusScheme) = 1

struct Magnus4State <: TimeDependentMatrixState
    H1::TimeDependentMatrixState
    H2::TimeDependentMatrixState
    f_dt::Float64
    s::Array{Complex{Float64},1}
    is_schroedinger_matrix::Bool
    function Magnus4State(H1, H2, f_dt, s, is_schroedinger_matrix=false)
        new(H1, H2, f_dt, s, is_schroedinger_matrix)
    end
end


struct Magnus4DerivativeState <: TimeDependentMatrixState
    H1::TimeDependentMatrixState
    H2::TimeDependentMatrixState
    H1d::TimeDependentMatrixState
    H2d::TimeDependentMatrixState
    dt::Float64
    f::Float64
    c1::Float64
    c2::Float64
    s::Array{Complex{Float64},1}
    s1::Array{Complex{Float64},1}
end


LinearAlgebra.size(H::Magnus4State) = size(H.H1)
LinearAlgebra.size(H::Magnus4State, dim::Int) = size(H.H1, dim) 
LinearAlgebra.eltype(H::Magnus4State) = eltype(H.H1) 
LinearAlgebra.issymmetric(H::Magnus4State) = issymmetric(H.H1) # TODO: check 
LinearAlgebra.ishermitian(H::Magnus4State) = ishermitian(H.H1) # TODO: check 
LinearAlgebra.checksquare(H::Magnus4State) = checksquare(H.H1)

LinearAlgebra.size(H::Magnus4DerivativeState) = size(H.H1)
LinearAlgebra.size(H::Magnus4DerivativeState, dim::Int) = size(H.H1, dim) 
LinearAlgebra.eltype(H::Magnus4DerivativeState) = eltype(H.H1) 
LinearAlgebra.issymmetric(H::Magnus4DerivativeState) = issymmetric(H.H1) # TODO: check 
LinearAlgebra.ishermitian(H::Magnus4DerivativeState) = ishermitian(H.H1) # TODO: check 
LinearAlgebra.checksquare(H::Magnus4DerivativeState) = checksquare(H.H1)



function LinearAlgebra.mul!(Y, H::Magnus4State, B)
    X = H.s 
    mul1!(X, H.H1, B)
    Y[:] = 0.5*X[:]
    mul1!(X, H.H2, X)
    Y[:] += H.f_dt*X[:]
    mul1!(X, H.H2, B)
    Y[:] += 0.5*X[:]
    mul1!(X, H.H1, X)
    Y[:] -= H.f_dt*X[:]
    if H.is_schroedinger_matrix
        Y[:] *= 1im
    end
end


function full(H::Magnus4State)     
    H1 = full(H.H1)
    H2 = full(H.H2)
    if H.is_schroedinger_matrix
        return 0.5*(H1+H2)+(1im*H.f_dt)*(H1*H2-H2*H1)
    else        
        return 0.5*(H1+H2)+H.f_dt*(H1*H2-H2*H1)
    end
end

function LinearAlgebra.mul!(Y, H::Magnus4DerivativeState, B)
    X = H.s 
    X1 = H.s1

    mul1!(X, H.H1d, B)
    Y[:] = (0.5*H.c1)*X[:]
    mul1!(X, H.H2, X)
    Y[:] += (H.f*H.c1*H.dt)*X[:]

    mul1!(X, H.H2d, B)
    Y[:] += (0.5*H.c2)*X[:] 
    mul1!(X, H.H1, X)
    Y[:] -= (H.f*H.c2*H.dt)*X[:]

    mul1!(X, H.H1, B)
    mul1!(X1, H.H2, X)
    Y[:] += H.f*X1[:]
    mul1!(X1, H.H2d, X)
    Y[:] += (H.f*H.c2*H.dt)*X1[:]

    mul1!(X, H.H2, B)
    mul1!(X1, H.H1, X)
    Y[:] -= H.f*X1[:]
    mul1!(X1, H.H1d, X)
    Y[:] -= (H.f*H.c1*H.dt)*X1[:]
end


function expmv1!(y, dt, H::Magnus4State, x, tol, m, wsp) 
    if H.is_schroedinger_matrix
        if tol==0
            y[:] = exp(-1im*dt*full(H))*x
        else
            expmv!(y, -1im*dt, H, x, tol=tol, m=m, wsp=wsp) 
        end
    else
        expmv1!(y, dt, H, x, tol, m, wsp)
    end
end

function step!(psi::Array{Complex{Float64},1}, H::TimeDependentMatrix, 
               t::Real, dt::Real, scheme::MagnusScheme,
               wsp::Vector{Vector{Complex{Float64}}}; 
               expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
    sqrt3 = sqrt(3)
    c1 = 1/2-sqrt3/6
    c2 = 1/2+sqrt3/6
    H1 = H(t + c1*dt)
    H2 = H(t + c2*dt)
    f = sqrt3/12
    s = wsp[expmv_m+3]
    HH = Magnus4State(H1, H2, f*dt, s, isa(H, TimeDependentSchroedingerMatrix))
    expmv1!(psi, dt, HH, psi, expmv_tol, expmv_m, wsp)
end  


function step_estimated!(psi::Array{Complex{Float64},1}, psi_est::Array{Complex{Float64},1},
                 H::TimeDependentMatrix, 
                 t::Real, dt::Real,
                 scheme::MagnusScheme,
                 wsp::Vector{Vector{Complex{Float64}}}; 
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
    s = wsp[1]
    s1 = wsp[2]
    s2 = wsp[3]
    s1a = wsp[4]
    s2a = wsp[5]
    
    sqrt3 = sqrt(3)
    f = sqrt3/12
    c1 = 1/2-sqrt3/6
    c2 = 1/2+sqrt3/6
    s3 = wsp[expmv_m+3]
    s4 = wsp[expmv_m+4]

    H1 = H(t + c1*dt)
    H2 = H(t + c2*dt)
    H1d = H(t + c1*dt, compute_derivative=true)
    H2d = H(t + c2*dt, compute_derivative=true)
    HH = Magnus4State(H1, H2, f*dt, s3)
    HHe = Magnus4State(H1, H2, f*dt, s3, isa(H, TimeDependentSchroedingerMatrix)) 
    if scheme.symmetrized_defect
        HHd = Magnus4DerivativeState(H1, H2, H1d, H2d, dt, f, c1-1/2, c2-1/2, s3, s4)
        H1 = H(t)
        mul1!(psi_est, H1, psi)
        psi_est[:] *= -0.5
    else
        HHd = Magnus4DerivativeState(H1, H2, H1d, H2d, dt, f, c1, c2, s3, s4)
        psi_est[:] .= 0.0
    end

    if scheme.trapezoidal_rule
        CC!(s, HH, HHd, psi, -1, dt, s1, s2)
        psi_est[:] += s[:]

        expmv1!(psi, dt, HHe, psi, expmv_tol, expmv_m, wsp)
        expmv1!(psi_est, dt, HHe, psi_est, expmv_tol, expmv_m, wsp)
        
        CC!(s, HH, HHd, psi, +1, dt, s1, s2)
        psi_est[:] += s[:]
    else
        if scheme.symmetrized_defect
            expmv1!(psi, dt, HHe, psi, expmv_tol, expmv_m, wsp)
            expmv1!(psi_est, dt, HHe, psi_est, expmv_tol, expmv_m, wsp)
        else
            expmv1!(psi, dt, HHe, psi, expmv_tol, expmv_m, wsp)
        end
    
        Gamma!(s, HH, HHd, psi, 4, dt, s1, s2, s1a, s2a, modified_Gamma=scheme.modified_Gamma)
        psi_est[:] += s[:]
    end

    H1 = H(t + dt)
    mul1!(s, H1, psi)
    if scheme.symmetrized_defect
        s[:] *= 0.5
    end
    psi_est[:] -= s[:]
    psi_est[:] *= (dt/5)
end



struct EquidistantTimeStepper
    H::TimeDependentMatrix
    psi::Array{Complex{Float64},1}
    t0::Float64
    tend::Float64
    dt::Float64
    scheme::Scheme
    expmv_tol::Float64
    expmv_m::Int
    wsp  :: Vector{Vector{Complex{Float64}}}  # workspace
    function EquidistantTimeStepper(H::TimeDependentMatrix, 
                 psi::Array{Complex{Float64},1},
                 t0::Real, tend::Real, dt::Real;
                 scheme::Scheme=CF4,
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))

        # allocate workspace
        lwsp = get_lwsp(H, scheme, expmv_m)
        wsp = [similar(psi) for k=1:lwsp]
        new(H, psi, t0, tend, dt, scheme, expmv_tol, expmv_m, wsp)
    end
end


function Base.iterate(ets::EquidistantTimeStepper, t=ets.t0)
    if t >= ets.tend
        return nothing
    end
    step!(ets.psi, ets.H, t, ets.dt, ets.scheme, ets.wsp, expmv_tol=ets.expmv_tol, expmv_m=ets.expmv_m)
    t1 = t + ets.dt < ets.tend ? t + ets.dt : ets.tend
    t1, t1
end


struct EquidistantCorrectedTimeStepper
    H::TimeDependentMatrix
    psi::Array{Complex{Float64},1}
    t0::Float64
    tend::Float64
    dt::Float64
    scheme::Scheme
    expmv_tol::Float64
    expmv_m::Int
    psi_est::Array{Complex{Float64},1}
    wsp  :: Vector{Vector{Complex{Float64}}}  # workspace

    function EquidistantCorrectedTimeStepper(H::TimeDependentMatrix, 
                 psi::Array{Complex{Float64},1},
                 t0::Real, tend::Real, dt::Real; 
                 scheme::Scheme=CF4,
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))

        # allocate workspace
        lwsp = max(5, get_lwsp(H, scheme, expmv_m))
        wsp = [similar(psi) for k=1:lwsp]

        psi_est = zeros(Complex{Float64}, size(H, 2))
        
        new(H, psi, t0, tend, dt, scheme, 
            expmv_tol, expmv_m, 
            psi_est, wsp)
    end
end


function Base.iterate(ets::EquidistantCorrectedTimeStepper, t=ets.t0)
    if t >= ets.tend
        return nothing
    end
    step_estimated!(ets.psi, ets.psi_est, ets.H, t, ets.dt, ets.scheme, ets.wsp,
                        expmv_tol=ets.expmv_tol, expmv_m=ets.expmv_m)
    ets.psi[:] -= ets.psi_est # corrected scheme                        
    t1 = t + ets.dt < ets.tend ? t + ets.dt : ets.tend
    t1, t1
end


using Printf

function local_orders(H::TimeDependentMatrix,
                      psi::Array{Complex{Float64},1}, t0::Real, dt::Real; 
                      scheme::Scheme=CF2, reference_scheme=scheme, 
                      reference_steps=10,
                      rows=8,
                      expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
    tab = zeros(Float64, rows, 4)

    # allocate workspace
    lwsp1 = get_lwsp(H, scheme, expmv_m)
    lwsp2 = get_lwsp(H, reference_scheme, expmv_m)
    lwsp = max(lwsp1, lwsp2)
    wsp = [similar(psi) for k=1:lwsp]

    wf_save_initial_value = copy(psi)
    psi_ref = copy(psi)

    dt1 = dt
    err_old = 0.0
    println("             dt         err      p    muls/dt")
    println("----------------------------------------------")
    for row=1:rows
        C0 = H.counter
        step!(psi, H, t0, dt1, scheme, wsp, expmv_tol=expmv_tol, expmv_m=expmv_m)
        C1 = H.counter
        copyto!(psi_ref, wf_save_initial_value)
        dt1_ref = dt1/reference_steps
        for k=1:reference_steps
            step!(psi_ref, H, t0+(k-1)*dt1_ref, dt1_ref, reference_scheme, wsp, expmv_tol=expmv_tol, expmv_m=expmv_m)
        end    
        err = norm(psi-psi_ref)
        muls_per_dt = (C1-C0)/dt1
        if (row==1) 
            @printf("%3i%12.3e%12.3e         %9.2f\n", row, Float64(dt1), Float64(err), Float64(muls_per_dt))
            tab[row,1] = dt1
            tab[row,2] = err
            tab[row,3] = 0 
            tab[row,4] = muls_per_dt 
        else
            p = log(err_old/err)/log(2.0);
            @printf("%3i%12.3e%12.3e%7.2f  %9.2f\n", row, Float64(dt1), Float64(err), Float64(p), Float64(muls_per_dt))
            tab[row,1] = dt1
            tab[row,2] = err
            tab[row,3] = p 
            tab[row,4] = muls_per_dt 
        end
        err_old = err
        dt1 = 0.5*dt1
        copyto!(psi, wf_save_initial_value)
    end

    tab
end

function local_orders_est(H::TimeDependentMatrix,
                      psi::Array{Complex{Float64},1}, t0::Real, dt::Real; 
                      scheme::Scheme=CF2_defectbased, reference_scheme=CF4, 
                      reference_steps=10,
                      rows=8,
                      expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
    tab = zeros(Float64, rows, 6)

    # allocate workspace
    lwsp1 = get_lwsp(H, scheme, expmv_m)
    lwsp2 = get_lwsp(H, reference_scheme, expmv_m)
    lwsp = max(5, lwsp1, lwsp2)
    wsp = [similar(psi) for k=1:lwsp]

    wf_save_initial_value = copy(psi)
    psi_ref = copy(psi)
    psi_est = copy(psi)

    dt1 = dt
    err_old = 0.0
    err_est_old = 0.0
    println("             dt         err      p       err_est      p    muls/dt")
    println("-------------------------------------------------------------------")
    for row=1:rows
        C0 = H.counter
        step_estimated!(psi, psi_est, H, t0, dt1, scheme,
                        wsp, expmv_tol=expmv_tol, expmv_m=expmv_m)
        C1 = H.counter
        copyto!(psi_ref, wf_save_initial_value)
        dt1_ref = dt1/reference_steps
        for k=1:reference_steps
            step!(psi_ref, H, t0+(k-1)*dt1_ref, dt1_ref, reference_scheme, wsp, expmv_tol=expmv_tol, expmv_m=expmv_m)
        end    
        err = norm(psi-psi_ref)
        err_est = norm(psi-psi_ref-psi_est)
        muls_per_dt = (C1-C0)/dt1
        if (row==1) 
            @printf("%3i%12.3e%12.3e  %19.3e         %9.2f\n", 
                    row, Float64(dt1), Float64(err), Float64(err_est), Float64(muls_per_dt))
            tab[row,1] = dt1
            tab[row,2] = err
            tab[row,3] = 0 
            tab[row,4] = err_est
            tab[row,5] = 0 
            tab[row,6] = muls_per_dt 
        else
            p = log(err_old/err)/log(2.0);
            p_est = log(err_est_old/err_est)/log(2.0);
            @printf("%3i%12.3e%12.3e%7.2f  %12.3e%7.2f  %9.2f\n", 
                    row, Float64(dt1), Float64(err), Float64(p), 
                    Float64(err_est), Float64(p_est), Float64(muls_per_dt))
            tab[row,1] = dt1
            tab[row,2] = err
            tab[row,3] = p 
            tab[row,4] = err_est
            tab[row,5] = p_est 
            tab[row,6] = muls_per_dt 
        end
        err_old = err
        err_est_old = err_est
        dt1 = 0.5*dt1
        copyto!(psi, wf_save_initial_value)
    end

    tab
end


function global_orders(H::TimeDependentMatrix,
                      psi::Array{Complex{Float64},1}, 
                      psi_ref::Array{Complex{Float64},1}, 
                      t0::Real, tend::Real, dt::Real; 
                      scheme::Scheme=CF2, rows=8,
                      expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)),
                      higher_order::Bool=false)
    tab = zeros(Float64, rows, 3)

    # allocate workspace
    lwsp = get_lwsp(H, scheme, expmv_m)
    wsp = [similar(psi) for k=1:lwsp]

    wf_save_initial_value = copy(psi)

    dt1 = dt
    err_old = 0.0
    println("             dt         err           C      p ")
    println("-----------------------------------------------")
    for row=1:rows
        if higher_order
            ets = EquidistantCorrectedTimeStepper(H, psi, t0, tend, dt1, 
                    scheme=scheme, expmv_tol=expmv_tol, expmv_m=expmv_m)
        else            
            ets = EquidistantTimeStepper(H, psi, t0, tend, dt1, 
                    scheme=scheme, expmv_tol=expmv_tol, expmv_m=expmv_m)
        end
        for t in ets end
        err = norm(psi-psi_ref)
        if (row==1) 
            @Printf.printf("%3i%12.3e%12.3e\n", row, Float64(dt1), Float64(err))
            tab[row,1] = dt1
            tab[row,2] = err
            tab[row,3] = 0 
        else
            p = log(err_old/err)/log(2.0)
            C = err/dt1^p
            @Printf.printf("%3i%12.3e%12.3e%12.3e%7.2f\n", row, Float64(dt1), Float64(err),
                                                       Float64(C), Float64(p))
            tab[row,1] = dt1
            tab[row,2] = err
            tab[row,3] = p 
        end
        err_old = err
        dt1 = 0.5*dt1
        copyto!(psi, wf_save_initial_value)
    end
end


struct AdaptiveTimeStepper
    H::TimeDependentMatrix
    psi::Array{Complex{Float64},1}
    t0::Float64
    tend::Float64
    dt::Float64
    tol::Float64
    order::Int
    scheme::Scheme
    dt_max::Float64
    higher_order::Bool
    expmv_tol::Float64
    expmv_m::Int
    psi_est::Array{Complex{Float64},1}
    psi0::Array{Complex{Float64},1}
    wsp  :: Vector{Vector{Complex{Float64}}}  # workspace

    """
    Iterator that steps through ODE solver.
    
        dpsi/dt = A(t) * psi(t)
    
    The local error is defined as:
    
        error = || psi(t+dt) -  psi_est(t+dt) ||_2
    
    Required arguments:
      - `H`:    Matrix for the ODE `A(t) = -i*H(t)`
      - `psi`:  On input, `psi(t0)`, will be updated with `psi(t)`
      - `t0`:   Initial time
      - `tend`: Final time
      - `dt`:   Guess for initial time step
      - `tol`:  Tolerance for local error
    
    Optional arguments:
      - `scheme`:             Integration scheme
      - `expmv_tol`:          Tolerance for Lanczos (0: full exp)
    """
    function AdaptiveTimeStepper(H::TimeDependentMatrix, 
                 psi::Array{Complex{Float64},1},
                 t0::Real, tend::Real, dt::Real,  tol::Real; 
                 scheme::Scheme=CF4,
                 dt_max::Real=Inf,
                 higher_order::Bool=false,
                 expmv_tol::Real=1e-7, expmv_m::Int=min(30, size(H,1)))
        order = get_order(scheme)

        # allocate workspace
        lwsp = max(5, get_lwsp(H, scheme, expmv_m))
        wsp = [similar(psi) for k=1:lwsp]

        psi_est = zeros(Complex{Float64}, size(H, 2))
        psi0 = zeros(Complex{Float64}, size(H, 2))
        
        new(H, psi, t0, tend, dt, tol, order, scheme, 
            dt_max, higher_order, expmv_tol, expmv_m, 
            psi_est, psi0, wsp)
    end
    
end

struct AdaptiveTimeStepperState
   t::Real
   dt::Real
end   

function Base.iterate(ats::AdaptiveTimeStepper, 
                      state::AdaptiveTimeStepperState=AdaptiveTimeStepperState(ats.t0, ats.dt))
    if state.t >= ats.tend
        return nothing
    end

    facmin = 0.25
    facmax = 4.0
    fac = 0.9

    dt = state.dt
    dt0 = dt
    ats.psi0[:] = ats.psi[:]
    err = 2.0
    while err>=1.0
        dt = min(dt, ats.tend-state.t, ats.dt_max)
        dt0 = dt
        step_estimated!(ats.psi, ats.psi_est, ats.H, state.t, dt, ats.scheme, ats.wsp,
                        expmv_tol=ats.expmv_tol, expmv_m=ats.expmv_m)
        err = norm(ats.psi_est)/ats.tol
        dt = dt*min(facmax, max(facmin, fac*(1.0/err)^(1.0/(ats.order+1))))
        if err>=1.0
           ats.psi[:] = ats.psi0
           @printf("t=%17.9e  err=%17.8e  dt=%17.8e  rejected...\n", Float64(state.t), Float64(err), Float64(dt))
        elseif ats.higher_order
           ats.psi[:] -= ats.psi_est # corrected scheme                        
        end
    end
    state.t + dt0, AdaptiveTimeStepperState(state.t+dt0, dt)
end







end #TimeDependentLinearODESystems
