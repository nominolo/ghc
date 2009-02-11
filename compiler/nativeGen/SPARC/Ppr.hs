-----------------------------------------------------------------------------
--
-- Pretty-printing assembly language
--
-- (c) The University of Glasgow 1993-2005
--
-----------------------------------------------------------------------------

module SPARC.Ppr (
	pprUserReg,
	pprSize,
	pprImm,
	pprSectionHeader,
	pprDataItem,
	pprInstr
)

where

#include "HsVersions.h"
#include "nativeGen/NCG.h"

import PprBase
import RegsBase
import SPARC.Regs
import SPARC.Instr

import BlockId
import Cmm

import CLabel

import Panic		( panic )
import Unique		( pprUnique )
import Pretty
import FastString


-- | Pretty print a register.
--	This is an alias of pprReg for legacy reasons, should remove it.
pprUserReg :: Reg -> Doc
pprUserReg = pprReg


-- | Pretty print a register.
pprReg :: Reg -> Doc
pprReg r
  = case r of
      RealReg i		-> pprReg_ofRegNo i
      VirtualRegI  u	-> text "%vI_"  <> asmSDoc (pprUnique u)
      VirtualRegHi u	-> text "%vHi_" <> asmSDoc (pprUnique u)
      VirtualRegF  u	-> text "%vF_"  <> asmSDoc (pprUnique u)
      VirtualRegD  u	-> text "%vD_"  <> asmSDoc (pprUnique u)


-- | Pretty print a register name, based on this register number.
--	The definition has been unfolded so we get a jump-table in the
--	object code. This function is called quite a lot when emitting the asm file..
--
pprReg_ofRegNo :: Int -> Doc
pprReg_ofRegNo i
 = ptext
    (case i of {
	 0 -> sLit "%g0";   1 -> sLit "%g1";
	 2 -> sLit "%g2";   3 -> sLit "%g3";
	 4 -> sLit "%g4";   5 -> sLit "%g5";
	 6 -> sLit "%g6";   7 -> sLit "%g7";
	 8 -> sLit "%o0";   9 -> sLit "%o1";
	10 -> sLit "%o2";  11 -> sLit "%o3";
	12 -> sLit "%o4";  13 -> sLit "%o5";
	14 -> sLit "%o6";  15 -> sLit "%o7";
	16 -> sLit "%l0";  17 -> sLit "%l1";
	18 -> sLit "%l2";  19 -> sLit "%l3";
	20 -> sLit "%l4";  21 -> sLit "%l5";
	22 -> sLit "%l6";  23 -> sLit "%l7";
	24 -> sLit "%i0";  25 -> sLit "%i1";
	26 -> sLit "%i2";  27 -> sLit "%i3";
	28 -> sLit "%i4";  29 -> sLit "%i5";
	30 -> sLit "%i6";  31 -> sLit "%i7";
	32 -> sLit "%f0";  33 -> sLit "%f1";
	34 -> sLit "%f2";  35 -> sLit "%f3";
	36 -> sLit "%f4";  37 -> sLit "%f5";
	38 -> sLit "%f6";  39 -> sLit "%f7";
	40 -> sLit "%f8";  41 -> sLit "%f9";
	42 -> sLit "%f10"; 43 -> sLit "%f11";
	44 -> sLit "%f12"; 45 -> sLit "%f13";
	46 -> sLit "%f14"; 47 -> sLit "%f15";
	48 -> sLit "%f16"; 49 -> sLit "%f17";
	50 -> sLit "%f18"; 51 -> sLit "%f19";
	52 -> sLit "%f20"; 53 -> sLit "%f21";
	54 -> sLit "%f22"; 55 -> sLit "%f23";
	56 -> sLit "%f24"; 57 -> sLit "%f25";
	58 -> sLit "%f26"; 59 -> sLit "%f27";
	60 -> sLit "%f28"; 61 -> sLit "%f29";
	62 -> sLit "%f30"; 63 -> sLit "%f31";
	_  -> sLit "very naughty sparc register" })


-- | Pretty print a size for an instruction suffix.
pprSize :: Size -> Doc
pprSize x 
 = ptext 
    (case x of
	II8   -> sLit "ub"
	II16  -> sLit "uh"
	II32  -> sLit ""
	II64  -> sLit "d"
	FF32  -> sLit ""
	FF64  -> sLit "d")


-- | Pretty print a size for an instruction suffix.
--	eg LD is 32bit on sparc, but LDD is 64 bit.
pprStSize :: Size -> Doc
pprStSize x 
 = ptext 
    (case x of
	II8   -> sLit "b"
	II16  -> sLit "h"
	II32  -> sLit ""
	II64  -> sLit "x"
	FF32  -> sLit ""
	FF64  -> sLit "d")

		
-- | Pretty print a condition code.
pprCond :: Cond -> Doc
pprCond c 
 = ptext 
    (case c of 
	ALWAYS	-> sLit ""
	NEVER 	-> sLit "n"
	GEU	-> sLit "geu"
	LU    	-> sLit "lu"
	EQQ	-> sLit "e"
	GTT   	-> sLit "g"
	GE	-> sLit "ge"
	GU	-> sLit "gu"
	LTT	-> sLit "l"
	LE	-> sLit "le"
	LEU	-> sLit "leu"
	NE	-> sLit "ne"
	NEG	-> sLit "neg"
	POS	-> sLit "pos"
	VC	-> sLit "vc"
	VS	-> sLit "vs")


-- | Pretty print an address mode.
pprAddr :: AddrMode -> Doc
pprAddr am
 = case am of
 	AddrRegReg r1 (RealReg 0)	
	 -> pprReg r1

	AddrRegReg r1 r2
	 -> hcat [ pprReg r1, char '+', pprReg r2 ]

	AddrRegImm r1 (ImmInt i)
	 | i == 0 		-> pprReg r1
	 | not (fits13Bits i) 	-> largeOffsetError i
	 | otherwise 		-> hcat [ pprReg r1, pp_sign, int i ]
	 where	
	 	pp_sign = if i > 0 then char '+' else empty

	AddrRegImm r1 (ImmInteger i)
	 | i == 0 		-> pprReg r1
	 | not (fits13Bits i)	-> largeOffsetError i
	 | otherwise		-> hcat [ pprReg r1, pp_sign, integer i ]
	 where
		pp_sign = if i > 0 then char '+' else empty

	AddrRegImm r1 imm
	 -> hcat [ pprReg r1, char '+', pprImm imm ]


-- | Pretty print an immediate value.
pprImm :: Imm -> Doc
pprImm imm
 = case imm of
 	ImmInt i	-> int i
	ImmInteger i	-> integer i
	ImmCLbl l	-> pprCLabel_asm l
	ImmIndex l i	-> pprCLabel_asm l <> char '+' <> int i
	ImmLit s	-> s

	ImmConstantSum a b	
	 -> pprImm a <> char '+' <> pprImm b

	ImmConstantDiff a b	
	 -> pprImm a <> char '-' <> lparen <> pprImm b <> rparen

	LO i
	 -> hcat [ text "%lo(", pprImm i, rparen ]
	
	HI i
	 -> hcat [ text "%hi(", pprImm i, rparen ]

	-- these should have been converted to bytes and placed
	--	in the data section.
	ImmFloat _	-> ptext (sLit "naughty float immediate")
	ImmDouble _	-> ptext (sLit "naughty double immediate")


-- | Pretty print a section \/ segment header.
--	On SPARC all the data sections must be at least 8 byte aligned
--	incase we store doubles in them.
--
pprSectionHeader :: Section -> Doc
pprSectionHeader seg
 = case seg of
 	Text			-> ptext (sLit ".text\n\t.align 4")
	Data			-> ptext (sLit ".data\n\t.align 8")
	ReadOnlyData		-> ptext (sLit ".text\n\t.align 8")
	RelocatableReadOnlyData	-> ptext (sLit ".text\n\t.align 8")
	UninitialisedData	-> ptext (sLit ".bss\n\t.align 8")
	ReadOnlyData16		-> ptext (sLit ".data\n\t.align 16")
	OtherSection _		-> panic "PprMach.pprSectionHeader: unknown section"


-- | Pretty print a data item.
pprDataItem :: CmmLit -> Doc
pprDataItem lit
  = vcat (ppr_item (cmmTypeSize $ cmmLitType lit) lit)
    where
	imm = litToImm lit

	ppr_item II8   _ 	= [ptext (sLit "\t.byte\t") <> pprImm imm]
	ppr_item II32  _	= [ptext (sLit "\t.long\t") <> pprImm imm]

	ppr_item FF32  (CmmFloat r _)
         = let bs = floatToBytes (fromRational r)
           in  map (\b -> ptext (sLit "\t.byte\t") <> pprImm (ImmInt b)) bs

    	ppr_item FF64 (CmmFloat r _)
         = let bs = doubleToBytes (fromRational r)
           in  map (\b -> ptext (sLit "\t.byte\t") <> pprImm (ImmInt b)) bs

	ppr_item II16  _	= [ptext (sLit "\t.short\t") <> pprImm imm]
	ppr_item II64  _	= [ptext (sLit "\t.quad\t") <> pprImm imm]
	ppr_item _ _		= panic "SPARC.Ppr.pprDataItem: no match"


-- | Pretty print an instruction.
pprInstr :: Instr -> Doc

-- nuke comments.
pprInstr (COMMENT _) 
	= empty 

pprInstr (DELTA d)
	= pprInstr (COMMENT (mkFastString ("\tdelta = " ++ show d)))

-- Newblocks and LData should have been slurped out before producing the .s file.
pprInstr (NEWBLOCK _)
	= panic "X86.Ppr.pprInstr: NEWBLOCK"

pprInstr (LDATA _ _)
	= panic "PprMach.pprInstr: LDATA"

pprInstr (SPILL reg slot)
 = hcat [
 	ptext (sLit "\tSPILL"),
	char '\t',
	pprReg reg,
	comma,
	ptext (sLit "SLOT") <> parens (int slot)]

pprInstr (RELOAD slot reg)
 = hcat [
	ptext (sLit "\tRELOAD"),
	char '\t',
	ptext (sLit "SLOT") <> parens (int slot),
	comma,
	pprReg reg]


-- a clumsy hack for now, to handle possible double alignment problems
-- even clumsier, to allow for RegReg regs that show when doing indexed
-- reads (bytearrays).

-- Translate to the following:
--    add g1,g2,g1
--    ld  [g1],%fn
--    ld  [g1+4],%f(n+1)
--    sub g1,g2,g1           -- to restore g1

pprInstr (LD FF64 (AddrRegReg g1 g2) reg)
 = let Just regH	= fPair reg
   in vcat [
       hcat [ptext (sLit "\tadd\t"), pprReg g1, comma, pprReg g2, comma, pprReg g1],
       hcat [pp_ld_lbracket, pprReg g1, pp_rbracket_comma, pprReg reg],
       hcat [pp_ld_lbracket, pprReg g1, ptext (sLit "+4]"), comma, pprReg regH],
       hcat [ptext (sLit "\tsub\t"), pprReg g1, comma, pprReg g2, comma, pprReg g1]
    ]

-- Translate to
--    ld  [addr],%fn
--    ld  [addr+4],%f(n+1)
pprInstr (LD FF64 addr reg)
 = let	Just addr2	= addrOffset addr 4
 	Just regH	= fPair reg
   in	vcat [
	       hcat [pp_ld_lbracket, pprAddr addr, pp_rbracket_comma, pprReg reg],
	       hcat [pp_ld_lbracket, pprAddr addr2, pp_rbracket_comma,pprReg regH]
	    ]

       
pprInstr (LD size addr reg)
 = hcat [
       ptext (sLit "\tld"),
       pprSize size,
       char '\t',
       lbrack,
       pprAddr addr,
       pp_rbracket_comma,
       pprReg reg
    ]

-- The same clumsy hack as above
-- Translate to the following:
--    add g1,g2,g1
--    st  %fn,[g1]
--    st  %f(n+1),[g1+4]
--    sub g1,g2,g1           -- to restore g1

pprInstr (ST FF64 reg (AddrRegReg g1 g2))
 = let	Just regH	= fPair reg
   in vcat [
       hcat [ptext (sLit "\tadd\t"),	pprReg g1,  comma, pprReg g2, comma, pprReg g1],
       hcat [ptext (sLit "\tst\t"),	pprReg reg, pp_comma_lbracket, 
             pprReg g1,	rbrack],
       hcat [ptext (sLit "\tst\t"), pprReg regH, pp_comma_lbracket,
             pprReg g1, ptext (sLit "+4]")],
       hcat [ptext (sLit "\tsub\t"), pprReg g1, comma, pprReg g2, comma, pprReg g1]
    ]

-- Translate to
--    st  %fn,[addr]
--    st  %f(n+1),[addr+4]
pprInstr (ST FF64 reg addr)
 = let	Just addr2	= addrOffset addr 4
	Just regH	= fPair reg
   in	vcat [
	      hcat [ptext (sLit "\tst\t"), pprReg reg, pp_comma_lbracket, 
	            pprAddr addr, rbrack],
	      hcat [ptext (sLit "\tst\t"), pprReg regH, pp_comma_lbracket,
	            pprAddr addr2, rbrack]
	    ]
    

-- no distinction is made between signed and unsigned bytes on stores for the
-- Sparc opcodes (at least I cannot see any, and gas is nagging me --SOF),
-- so we call a special-purpose pprSize for ST..
pprInstr (ST size reg addr)
  = hcat [
       ptext (sLit "\tst"),
       pprStSize size,
       char '\t',
       pprReg reg,
       pp_comma_lbracket,
       pprAddr addr,
       rbrack
    ]


pprInstr (ADD x cc reg1 ri reg2)
	| not x && not cc && riZero ri
	= hcat [ ptext (sLit "\tmov\t"), pprReg reg1, comma, pprReg reg2 ]

	| otherwise
	= pprRegRIReg (if x then sLit "addx" else sLit "add") cc reg1 ri reg2


pprInstr (SUB x cc reg1 ri reg2)
	| not x && cc && reg2 == g0
	= hcat [ ptext (sLit "\tcmp\t"), pprReg reg1, comma, pprRI ri ]

	| not x && not cc && riZero ri
	= hcat [ ptext (sLit "\tmov\t"), pprReg reg1, comma, pprReg reg2 ]
	
	| otherwise
	= pprRegRIReg (if x then sLit "subx" else sLit "sub") cc reg1 ri reg2

pprInstr (AND  b reg1 ri reg2)	= pprRegRIReg (sLit "and")  b reg1 ri reg2

pprInstr (ANDN b reg1 ri reg2)	= pprRegRIReg (sLit "andn") b reg1 ri reg2

pprInstr (OR b reg1 ri reg2)
	| not b && reg1 == g0
	= let doit = hcat [ ptext (sLit "\tmov\t"), pprRI ri, comma, pprReg reg2 ]
	  in  case ri of
	           RIReg rrr | rrr == reg2 -> empty
	           _                       -> doit

	| otherwise
	= pprRegRIReg (sLit "or") b reg1 ri reg2

pprInstr (ORN b reg1 ri reg2)	= pprRegRIReg (sLit "orn") b reg1 ri reg2

pprInstr (XOR  b reg1 ri reg2)	= pprRegRIReg (sLit "xor")  b reg1 ri reg2
pprInstr (XNOR b reg1 ri reg2)	= pprRegRIReg (sLit "xnor") b reg1 ri reg2

pprInstr (SLL reg1 ri reg2)	= pprRegRIReg (sLit "sll") False reg1 ri reg2
pprInstr (SRL reg1 ri reg2)	= pprRegRIReg (sLit "srl") False reg1 ri reg2
pprInstr (SRA reg1 ri reg2)	= pprRegRIReg (sLit "sra") False reg1 ri reg2

pprInstr (RDY rd) 		= ptext (sLit "\trd\t%y,") <> pprReg rd
pprInstr (WRY reg1 reg2) 	
	= ptext (sLit "\twr\t") 
		<> pprReg reg1 
		<> char ','
		<> pprReg reg2
		<> char ','
		<> ptext (sLit "%y") 

pprInstr (SMUL b reg1 ri reg2)	= pprRegRIReg (sLit "smul")  b reg1 ri reg2
pprInstr (UMUL b reg1 ri reg2)	= pprRegRIReg (sLit "umul")  b reg1 ri reg2
pprInstr (SDIV b reg1 ri reg2)	= pprRegRIReg (sLit "sdiv")  b reg1 ri reg2
pprInstr (UDIV b reg1 ri reg2)	= pprRegRIReg (sLit "udiv")  b reg1 ri reg2

pprInstr (SETHI imm reg)
  = hcat [
	ptext (sLit "\tsethi\t"),
	pprImm imm,
	comma,
	pprReg reg
    ]

pprInstr NOP = ptext (sLit "\tnop")

pprInstr (FABS FF32 reg1 reg2)	= pprSizeRegReg (sLit "fabs") FF32 reg1 reg2
pprInstr (FABS FF64 reg1 reg2)
 = let	Just reg1H	= fPair reg1
 	Just reg2H	= fPair reg2
   in
    (<>) (pprSizeRegReg (sLit "fabs") FF32 reg1 reg2)
    (if (reg1 == reg2) then empty
     else (<>) (char '\n')
    	  (pprSizeRegReg (sLit "fmov") FF32 reg1H reg2H))

pprInstr (FABS _ _ _)
 =panic "SPARC.Ppr.pprInstr(FABS): no match"

pprInstr (FADD size reg1 reg2 reg3)	
	= pprSizeRegRegReg (sLit "fadd") size reg1 reg2 reg3

pprInstr (FCMP e size reg1 reg2)
	= pprSizeRegReg (if e then sLit "fcmpe" else sLit "fcmp") size reg1 reg2

pprInstr (FDIV size reg1 reg2 reg3)
	= pprSizeRegRegReg (sLit "fdiv") size reg1 reg2 reg3

pprInstr (FMOV FF32 reg1 reg2)	= pprSizeRegReg (sLit "fmov") FF32 reg1 reg2
pprInstr (FMOV FF64 reg1 reg2)	= pprSizeRegReg (sLit "fmov") FF64 reg1 reg2

pprInstr (FMOV _ _ _)
 =	panic "SPARC.Ppr.pprInstr(FMOV): no match"

{-
pprInstr (FMOV FF64 reg1 reg2)
 = let	Just reg1H	= fPair reg1
 	Just reg2H	= fPair reg2
   in
    (<>) (pprSizeRegReg (sLit "fmov") FF32 reg1 reg2)
    (if (reg1 == reg2) then empty
     else (<>) (char '\n')
    	  (pprSizeRegReg (sLit "fmov") FF32 reg1H reg2H))
-}

pprInstr (FMUL size reg1 reg2 reg3)
	= pprSizeRegRegReg (sLit "fmul") size reg1 reg2 reg3

pprInstr (FNEG FF32 reg1 reg2) 
	= pprSizeRegReg (sLit "fneg") FF32 reg1 reg2

pprInstr (FNEG FF64 reg1 reg2)
 = let	Just reg1H	= fPair reg1
 	Just reg2H	= fPair reg2
   in
    (<>) (pprSizeRegReg (sLit "fneg") FF32 reg1 reg2)
    (if (reg1 == reg2) then empty
     else (<>) (char '\n')
    	  (pprSizeRegReg (sLit "fmov") FF32 reg1H reg2H))

pprInstr (FNEG _ _ _)
	= panic "SPARC.Ppr.pprInstr(FNEG): no match"

pprInstr (FSQRT size reg1 reg2)     
	= pprSizeRegReg (sLit "fsqrt") size reg1 reg2

pprInstr (FSUB size reg1 reg2 reg3) 
	= pprSizeRegRegReg (sLit "fsub") size reg1 reg2 reg3

pprInstr (FxTOy size1 size2 reg1 reg2)
  = hcat [
    	ptext (sLit "\tf"),
	ptext
    	(case size1 of
    	    II32  -> sLit "ito"
    	    FF32  -> sLit "sto"
    	    FF64  -> sLit "dto"
	    _	  -> panic "SPARC.Ppr.pprInstr.FxToY: no match"),
	ptext
    	(case size2 of
    	    II32  -> sLit "i\t"
	    II64  -> sLit "x\t"
    	    FF32  -> sLit "s\t"
    	    FF64  -> sLit "d\t"
	    _	  -> panic "SPARC.Ppr.pprInstr.FxToY: no match"),
	pprReg reg1, comma, pprReg reg2
    ]


pprInstr (BI cond b (BlockId id))
  = hcat [
	ptext (sLit "\tb"), pprCond cond,
	if b then pp_comma_a else empty,
	char '\t',
	pprCLabel_asm (mkAsmTempLabel id)
    ]

pprInstr (BF cond b (BlockId id))
  = hcat [
	ptext (sLit "\tfb"), pprCond cond,
	if b then pp_comma_a else empty,
	char '\t',
	pprCLabel_asm (mkAsmTempLabel id)
    ]

pprInstr (JMP addr) = (<>) (ptext (sLit "\tjmp\t")) (pprAddr addr)
pprInstr (JMP_TBL op _)  = pprInstr (JMP op)

pprInstr (CALL (Left imm) n _)
  = hcat [ ptext (sLit "\tcall\t"), pprImm imm, comma, int n ]
pprInstr (CALL (Right reg) n _)
  = hcat [ ptext (sLit "\tcall\t"), pprReg reg, comma, int n ]


-- | Pretty print a RI
pprRI :: RI -> Doc
pprRI (RIReg r) = pprReg r
pprRI (RIImm r) = pprImm r


-- | Pretty print a two reg instruction.
pprSizeRegReg :: LitString -> Size -> Reg -> Reg -> Doc
pprSizeRegReg name size reg1 reg2
  = hcat [
    	char '\t',
	ptext name,
    	(case size of
    	    FF32 -> ptext (sLit "s\t")
    	    FF64 -> ptext (sLit "d\t")
	    _    -> panic "SPARC.Ppr.pprSizeRegReg: no match"),

	pprReg reg1,
	comma,
	pprReg reg2
    ]


-- | Pretty print a three reg instruction.
pprSizeRegRegReg :: LitString -> Size -> Reg -> Reg -> Reg -> Doc
pprSizeRegRegReg name size reg1 reg2 reg3
  = hcat [
    	char '\t',
	ptext name,
    	(case size of
    	    FF32  -> ptext (sLit "s\t")
    	    FF64  -> ptext (sLit "d\t")
	    _    -> panic "SPARC.Ppr.pprSizeRegReg: no match"),
	pprReg reg1,
	comma,
	pprReg reg2,
	comma,
	pprReg reg3
    ]


-- | Pretty print an instruction of two regs and a ri.
pprRegRIReg :: LitString -> Bool -> Reg -> RI -> Reg -> Doc
pprRegRIReg name b reg1 ri reg2
  = hcat [
	char '\t',
	ptext name,
	if b then ptext (sLit "cc\t") else char '\t',
	pprReg reg1,
	comma,
	pprRI ri,
	comma,
	pprReg reg2
    ]

{-
pprRIReg :: LitString -> Bool -> RI -> Reg -> Doc
pprRIReg name b ri reg1
  = hcat [
	char '\t',
	ptext name,
	if b then ptext (sLit "cc\t") else char '\t',
	pprRI ri,
	comma,
	pprReg reg1
    ]
-}


pp_ld_lbracket :: Doc
pp_ld_lbracket    = ptext (sLit "\tld\t[")


pp_rbracket_comma :: Doc
pp_rbracket_comma = text "],"


pp_comma_lbracket :: Doc
pp_comma_lbracket = text ",["


pp_comma_a :: Doc
pp_comma_a	  = text ",a"
