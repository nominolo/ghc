module X86.Regs (
	-- squeese functions for the graph allocator
	virtualRegSqueeze,
	realRegSqueeze,

	-- immediates
	Imm(..),
	strImmLit,
	litToImm,

	-- addressing modes
	AddrMode(..),
	addrOffset,

	-- registers
	spRel,
	argRegs,
	allArgRegs,
	callClobberedRegs,
	allMachRegNos,
	classOfRealReg,
	showReg,	

	-- machine specific
	EABase(..), EAIndex(..), addrModeRegs,

	eax, ebx, ecx, edx, esi, edi, ebp, esp,
	fake0, fake1, fake2, fake3, fake4, fake5, firstfake,

	rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp,
	r8,  r9,  r10, r11, r12, r13, r14, r15,
  	xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7,
  	xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15,
	xmm,

	ripRel,
	allFPArgRegs,

	-- horror show
	freeReg,
	globalRegMaybe,
	
	allocatableRegs
)

where

#include "nativeGen/NCG.h"
#include "HsVersions.h"

#include "../includes/stg/MachRegs.h"

import Reg
import RegClass

import BlockId
import OldCmm
import CLabel           ( CLabel )
import Pretty
import Outputable	( panic )
import FastTypes
import FastBool


#if  defined(i386_TARGET_ARCH) || defined(x86_64_TARGET_ARCH)
import Constants
#endif


-- | regSqueeze_class reg
--	Calculuate the maximum number of register colors that could be
--	denied to a node of this class due to having this reg 
--	as a neighbour.
--
{-# INLINE virtualRegSqueeze #-}
virtualRegSqueeze :: RegClass -> VirtualReg -> FastInt

virtualRegSqueeze cls vr
 = case cls of
 	RcInteger
	 -> case vr of
	 	VirtualRegI{}		-> _ILIT(1)
		VirtualRegHi{}		-> _ILIT(1)
                _other                  -> _ILIT(0)

	RcDouble
	 -> case vr of
		VirtualRegD{}		-> _ILIT(1)
		VirtualRegF{}		-> _ILIT(0)
                _other                  -> _ILIT(0)

	RcDoubleSSE
	 -> case vr of
		VirtualRegSSE{}		-> _ILIT(1)
                _other                  -> _ILIT(0)

        _other -> _ILIT(0)

{-# INLINE realRegSqueeze #-}
realRegSqueeze :: RegClass -> RealReg -> FastInt
realRegSqueeze cls rr
 = case cls of
 	RcInteger
	 -> case rr of
	 	RealRegSingle regNo
			| regNo	< firstfake -> _ILIT(1)
			| otherwise	-> _ILIT(0)
			
		RealRegPair{}		-> _ILIT(0)

	RcDouble
	 -> case rr of
	 	RealRegSingle regNo
			| regNo >= firstfake && regNo <= lastfake -> _ILIT(1)
			| otherwise	-> _ILIT(0)
			
		RealRegPair{}		-> _ILIT(0)

        RcDoubleSSE
	 -> case rr of
	 	RealRegSingle regNo | regNo >= firstxmm -> _ILIT(1)
                _otherwise                        -> _ILIT(0)

        _other -> _ILIT(0)

-- -----------------------------------------------------------------------------
-- Immediates

data Imm
  = ImmInt	Int
  | ImmInteger	Integer	    -- Sigh.
  | ImmCLbl	CLabel	    -- AbstractC Label (with baggage)
  | ImmLit	Doc	    -- Simple string
  | ImmIndex    CLabel Int
  | ImmFloat	Rational
  | ImmDouble	Rational
  | ImmConstantSum Imm Imm
  | ImmConstantDiff Imm Imm


strImmLit :: String -> Imm
strImmLit s = ImmLit (text s)


litToImm :: CmmLit -> Imm
litToImm (CmmInt i w)        = ImmInteger (narrowS w i)
                -- narrow to the width: a CmmInt might be out of
                -- range, but we assume that ImmInteger only contains
                -- in-range values.  A signed value should be fine here.
litToImm (CmmFloat f W32)    = ImmFloat f
litToImm (CmmFloat f W64)    = ImmDouble f
litToImm (CmmLabel l)        = ImmCLbl l
litToImm (CmmLabelOff l off) = ImmIndex l off
litToImm (CmmLabelDiffOff l1 l2 off)
                             = ImmConstantSum
                               (ImmConstantDiff (ImmCLbl l1) (ImmCLbl l2))
                               (ImmInt off)
litToImm (CmmBlock id)       = ImmCLbl (infoTblLbl id)
litToImm _                   = panic "X86.Regs.litToImm: no match"

-- addressing modes ------------------------------------------------------------

data AddrMode
	= AddrBaseIndex	EABase EAIndex Displacement
	| ImmAddr Imm Int

data EABase       = EABaseNone  | EABaseReg Reg | EABaseRip
data EAIndex      = EAIndexNone | EAIndex Reg Int
type Displacement = Imm


addrOffset :: AddrMode -> Int -> Maybe AddrMode
addrOffset addr off
  = case addr of
      ImmAddr i off0	  -> Just (ImmAddr i (off0 + off))

      AddrBaseIndex r i (ImmInt n) -> Just (AddrBaseIndex r i (ImmInt (n + off)))
      AddrBaseIndex r i (ImmInteger n)
	-> Just (AddrBaseIndex r i (ImmInt (fromInteger (n + toInteger off))))

      AddrBaseIndex r i (ImmCLbl lbl)
	-> Just (AddrBaseIndex r i (ImmIndex lbl off))

      AddrBaseIndex r i (ImmIndex lbl ix)
	-> Just (AddrBaseIndex r i (ImmIndex lbl (ix+off)))

      _ -> Nothing  -- in theory, shouldn't happen


addrModeRegs :: AddrMode -> [Reg]
addrModeRegs (AddrBaseIndex b i _) =  b_regs ++ i_regs
  where
   b_regs = case b of { EABaseReg r -> [r]; _ -> [] }
   i_regs = case i of { EAIndex r _ -> [r]; _ -> [] }
addrModeRegs _ = []


-- registers -------------------------------------------------------------------

-- @spRel@ gives us a stack relative addressing mode for volatile
-- temporaries and for excess call arguments.  @fpRel@, where
-- applicable, is the same but for the frame pointer.


spRel :: Int		-- ^ desired stack offset in words, positive or negative
      -> AddrMode

#if   i386_TARGET_ARCH
spRel n	= AddrBaseIndex (EABaseReg esp) EAIndexNone (ImmInt (n * wORD_SIZE))

#elif x86_64_TARGET_ARCH
spRel n	= AddrBaseIndex (EABaseReg rsp) EAIndexNone (ImmInt (n * wORD_SIZE))

#else
spRel _	= panic "X86.Regs.spRel: not defined for this architecture"

#endif

-- The register numbers must fit into 32 bits on x86, so that we can
-- use a Word32 to represent the set of free registers in the register
-- allocator.

firstfake, lastfake :: RegNo
firstfake = 16
lastfake  = 21

firstxmm, lastxmm :: RegNo
firstxmm  = 24
#if i386_TARGET_ARCH
lastxmm   = 31
#else
lastxmm   = 39
#endif

lastint :: RegNo
#if i386_TARGET_ARCH
lastint = 7 -- not %r8..%r15
#else
lastint = 15
#endif

intregnos, fakeregnos, xmmregnos, floatregnos :: [RegNo]
intregnos   = [0..lastint]
fakeregnos  = [firstfake .. lastfake]
xmmregnos   = [firstxmm  .. lastxmm]
floatregnos = fakeregnos ++ xmmregnos;


-- argRegs is the set of regs which are read for an n-argument call to C.
-- For archs which pass all args on the stack (x86), is empty.
-- Sparc passes up to the first 6 args in regs.
-- Dunno about Alpha.
argRegs :: RegNo -> [Reg]
argRegs _	= panic "MachRegs.argRegs(x86): should not be used!"

-- | The complete set of machine registers.
allMachRegNos :: [RegNo]
allMachRegNos  = intregnos ++ floatregnos

-- | Take the class of a register.
{-# INLINE classOfRealReg      #-}
classOfRealReg :: RealReg -> RegClass
-- On x86, we might want to have an 8-bit RegClass, which would
-- contain just regs 1-4 (the others don't have 8-bit versions).
-- However, we can get away without this at the moment because the
-- only allocatable integer regs are also 8-bit compatible (1, 3, 4).
classOfRealReg reg
 = case reg of
	RealRegSingle i
          | i <= lastint  -> RcInteger
          | i <= lastfake -> RcDouble
          | otherwise     -> RcDoubleSSE

	RealRegPair{}	-> panic "X86.Regs.classOfRealReg: RegPairs on this arch"

-- | Get the name of the register with this number.
showReg :: RegNo -> String
showReg n
	| n >= firstxmm	 = "%xmm" ++ show (n-firstxmm)
        | n >= firstfake = "%fake" ++ show (n-firstfake)
	| n >= 8	 = "%r" ++ show n
	| otherwise	 = regNames !! n

regNames :: [String]
regNames 
#if   i386_TARGET_ARCH
   = ["%eax", "%ebx", "%ecx", "%edx", "%esi", "%edi", "%ebp", "%esp"]
#elif x86_64_TARGET_ARCH
   = ["%rax", "%rbx", "%rcx", "%rdx", "%rsi", "%rdi", "%rbp", "%rsp" ]
#else
   = []
#endif



-- machine specific ------------------------------------------------------------


{-
Intel x86 architecture:
- All registers except 7 (esp) are available for use.
- Only ebx, esi, edi and esp are available across a C call (they are callee-saves).
- Registers 0-7 have 16-bit counterparts (ax, bx etc.)
- Registers 0-3 have 8 bit counterparts (ah, bh etc.)
- Registers fake0..fake5 are fakes; we pretend x86 has 6 conventionally-addressable
  fp registers, and 3-operand insns for them, and we translate this into
  real stack-based x86 fp code after register allocation.

The fp registers are all Double registers; we don't have any RcFloat class
regs.  @regClass@ barfs if you give it a VirtualRegF, and mkVReg above should
never generate them.
-}

fake0, fake1, fake2, fake3, fake4, fake5, 
       eax, ebx, ecx, edx, esp, ebp, esi, edi :: Reg

eax   = regSingle 0
ebx   = regSingle 1
ecx   = regSingle 2
edx   = regSingle 3
esi   = regSingle 4
edi   = regSingle 5
ebp   = regSingle 6
esp   = regSingle 7
fake0 = regSingle 16
fake1 = regSingle 17
fake2 = regSingle 18
fake3 = regSingle 19
fake4 = regSingle 20
fake5 = regSingle 21



{-
AMD x86_64 architecture:
- Registers 0-16 have 32-bit counterparts (eax, ebx etc.)
- Registers 0-7 have 16-bit counterparts (ax, bx etc.)
- Registers 0-3 have 8 bit counterparts (ah, bh etc.)

-}

rax, rbx, rcx, rdx, rsp, rbp, rsi, rdi, 
  r8, r9, r10, r11, r12, r13, r14, r15,
  xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7,
  xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15 :: Reg

rax   = regSingle 0
rbx   = regSingle 1
rcx   = regSingle 2
rdx   = regSingle 3
rsi   = regSingle 4
rdi   = regSingle 5
rbp   = regSingle 6
rsp   = regSingle 7
r8    = regSingle 8
r9    = regSingle 9
r10   = regSingle 10
r11   = regSingle 11
r12   = regSingle 12
r13   = regSingle 13
r14   = regSingle 14
r15   = regSingle 15
xmm0  = regSingle 24
xmm1  = regSingle 25
xmm2  = regSingle 26
xmm3  = regSingle 27
xmm4  = regSingle 28
xmm5  = regSingle 29
xmm6  = regSingle 30
xmm7  = regSingle 31
xmm8  = regSingle 32
xmm9  = regSingle 33
xmm10 = regSingle 34
xmm11 = regSingle 35
xmm12 = regSingle 36
xmm13 = regSingle 37
xmm14 = regSingle 38
xmm15 = regSingle 39

allFPArgRegs :: [Reg]
allFPArgRegs	= map regSingle [firstxmm .. firstxmm+7]

ripRel :: Displacement -> AddrMode
ripRel imm	= AddrBaseIndex EABaseRip EAIndexNone imm


 -- so we can re-use some x86 code:
{-
eax = rax
ebx = rbx
ecx = rcx
edx = rdx
esi = rsi
edi = rdi
ebp = rbp
esp = rsp
-}

xmm :: RegNo -> Reg
xmm n = regSingle (firstxmm+n)




-- horror show -----------------------------------------------------------------
freeReg 		:: RegNo -> FastBool
globalRegMaybe 		:: GlobalReg -> Maybe RealReg
allArgRegs 		:: [Reg]
callClobberedRegs 	:: [Reg]

#if defined(i386_TARGET_ARCH) || defined(x86_64_TARGET_ARCH)

#if i386_TARGET_ARCH
#define eax 0
#define ebx 1
#define ecx 2
#define edx 3
#define esi 4
#define edi 5
#define ebp 6
#define esp 7
#endif

#if x86_64_TARGET_ARCH
#define rax   0
#define rbx   1
#define rcx   2
#define rdx   3
#define rsi   4
#define rdi   5
#define rbp   6
#define rsp   7
#define r8    8
#define r9    9
#define r10   10
#define r11   11
#define r12   12
#define r13   13
#define r14   14
#define r15   15
#endif

#define fake0 16
#define fake1 17
#define fake2 18
#define fake3 19
#define fake4 20
#define fake5 21

#define xmm0  24
#define xmm1  25
#define xmm2  26
#define xmm3  27
#define xmm4  28
#define xmm5  29
#define xmm6  30
#define xmm7  31
#define xmm8  32
#define xmm9  33
#define xmm10 34
#define xmm11 35
#define xmm12 36
#define xmm13 37
#define xmm14 38
#define xmm15 39

#if i386_TARGET_ARCH
freeReg esp = fastBool False  --	%esp is the C stack pointer
#endif

#if x86_64_TARGET_ARCH
freeReg rsp = fastBool False  --	%rsp is the C stack pointer
#endif

#ifdef REG_Base
freeReg REG_Base = fastBool False
#endif
#ifdef REG_R1
freeReg REG_R1   = fastBool False
#endif	
#ifdef REG_R2  
freeReg REG_R2   = fastBool False
#endif	
#ifdef REG_R3  
freeReg REG_R3   = fastBool False
#endif	
#ifdef REG_R4  
freeReg REG_R4   = fastBool False
#endif	
#ifdef REG_R5  
freeReg REG_R5   = fastBool False
#endif	
#ifdef REG_R6  
freeReg REG_R6   = fastBool False
#endif	
#ifdef REG_R7  
freeReg REG_R7   = fastBool False
#endif	
#ifdef REG_R8  
freeReg REG_R8   = fastBool False
#endif
#ifdef REG_F1
freeReg REG_F1 = fastBool False
#endif
#ifdef REG_F2
freeReg REG_F2 = fastBool False
#endif
#ifdef REG_F3
freeReg REG_F3 = fastBool False
#endif
#ifdef REG_F4
freeReg REG_F4 = fastBool False
#endif
#ifdef REG_D1
freeReg REG_D1 = fastBool False
#endif
#ifdef REG_D2
freeReg REG_D2 = fastBool False
#endif
#ifdef REG_Sp 
freeReg REG_Sp   = fastBool False
#endif 
#ifdef REG_Su
freeReg REG_Su   = fastBool False
#endif 
#ifdef REG_SpLim 
freeReg REG_SpLim = fastBool False
#endif 
#ifdef REG_Hp 
freeReg REG_Hp   = fastBool False
#endif
#ifdef REG_HpLim
freeReg REG_HpLim = fastBool False
#endif
freeReg _               = fastBool True


--  | Returns 'Nothing' if this global register is not stored
-- in a real machine register, otherwise returns @'Just' reg@, where
-- reg is the machine register it is stored in.

#ifdef REG_Base
globalRegMaybe BaseReg			= Just (RealRegSingle REG_Base)
#endif
#ifdef REG_R1
globalRegMaybe (VanillaReg 1 _)		= Just (RealRegSingle REG_R1)
#endif 
#ifdef REG_R2 
globalRegMaybe (VanillaReg 2 _)		= Just (RealRegSingle REG_R2)
#endif 
#ifdef REG_R3 
globalRegMaybe (VanillaReg 3 _) 	= Just (RealRegSingle REG_R3)
#endif 
#ifdef REG_R4 
globalRegMaybe (VanillaReg 4 _)		= Just (RealRegSingle REG_R4)
#endif 
#ifdef REG_R5 
globalRegMaybe (VanillaReg 5 _)		= Just (RealRegSingle REG_R5)
#endif 
#ifdef REG_R6 
globalRegMaybe (VanillaReg 6 _)		= Just (RealRegSingle REG_R6)
#endif 
#ifdef REG_R7 
globalRegMaybe (VanillaReg 7 _)		= Just (RealRegSingle REG_R7)
#endif 
#ifdef REG_R8 
globalRegMaybe (VanillaReg 8 _)		= Just (RealRegSingle REG_R8)
#endif
#ifdef REG_R9 
globalRegMaybe (VanillaReg 9 _)		= Just (RealRegSingle REG_R9)
#endif
#ifdef REG_R10 
globalRegMaybe (VanillaReg 10 _)	= Just (RealRegSingle REG_R10)
#endif
#ifdef REG_F1
globalRegMaybe (FloatReg 1)		= Just (RealRegSingle REG_F1)
#endif				 	
#ifdef REG_F2			 	
globalRegMaybe (FloatReg 2)		= Just (RealRegSingle REG_F2)
#endif				 	
#ifdef REG_F3			 	
globalRegMaybe (FloatReg 3)		= Just (RealRegSingle REG_F3)
#endif				 	
#ifdef REG_F4			 	
globalRegMaybe (FloatReg 4)		= Just (RealRegSingle REG_F4)
#endif				 	
#ifdef REG_D1			 	
globalRegMaybe (DoubleReg 1)		= Just (RealRegSingle REG_D1)
#endif				 	
#ifdef REG_D2			 	
globalRegMaybe (DoubleReg 2)		= Just (RealRegSingle REG_D2)
#endif
#ifdef REG_Sp	    
globalRegMaybe Sp		   	= Just (RealRegSingle REG_Sp)
#endif
#ifdef REG_Lng1			 	
globalRegMaybe (LongReg 1)		= Just (RealRegSingle REG_Lng1)
#endif				 	
#ifdef REG_Lng2			 	
globalRegMaybe (LongReg 2)		= Just (RealRegSingle REG_Lng2)
#endif
#ifdef REG_SpLim	    			
globalRegMaybe SpLim		   	= Just (RealRegSingle REG_SpLim)
#endif	    				
#ifdef REG_Hp	   			
globalRegMaybe Hp		   	= Just (RealRegSingle REG_Hp)
#endif	    				
#ifdef REG_HpLim      			
globalRegMaybe HpLim		   	= Just (RealRegSingle REG_HpLim)
#endif	    				
#ifdef REG_CurrentTSO      			
globalRegMaybe CurrentTSO	   	= Just (RealRegSingle REG_CurrentTSO)
#endif	    				
#ifdef REG_CurrentNursery      			
globalRegMaybe CurrentNursery	   	= Just (RealRegSingle REG_CurrentNursery)
#endif	    				
globalRegMaybe _		   	= Nothing

-- 

#if   i386_TARGET_ARCH
allArgRegs = panic "X86.Regs.allArgRegs: should not be used!"

#elif x86_64_TARGET_ARCH
allArgRegs = map regSingle [rdi,rsi,rdx,rcx,r8,r9]

#else
allArgRegs  = panic "X86.Regs.allArgRegs: not defined for this architecture"
#endif


-- | these are the regs which we cannot assume stay alive over a C call.  

#if   i386_TARGET_ARCH
-- caller-saves registers
callClobberedRegs
  = map regSingle ([eax,ecx,edx]  ++ floatregnos)

#elif x86_64_TARGET_ARCH
-- all xmm regs are caller-saves
-- caller-saves registers
callClobberedRegs    
  = map regSingle ([rax,rcx,rdx,rsi,rdi,r8,r9,r10,r11] ++ floatregnos)

#else
callClobberedRegs
  = panic "X86.Regs.callClobberedRegs: not defined for this architecture"
#endif

#else /* i386_TARGET_ARCH || x86_64_TARGET_ARCH */



freeReg	_		= 0#
globalRegMaybe _	= panic "X86.Regs.globalRegMaybe: not defined"

allArgRegs		= panic "X86.Regs.globalRegMaybe: not defined"
callClobberedRegs	= panic "X86.Regs.globalRegMaybe: not defined"


#endif

-- allocatableRegs is allMachRegNos with the fixed-use regs removed.
-- i.e., these are the regs for which we are prepared to allow the
-- register allocator to attempt to map VRegs to.
allocatableRegs :: [RealReg]
allocatableRegs
   = let isFree i = isFastTrue (freeReg i)
     in  map RealRegSingle $ filter isFree allMachRegNos


