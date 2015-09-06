local FistaL1, parent = torch.class('unsup.FistaL1','unsup.UnsupModule')
-- inputFeatures   : number of input features
-- outputFeatures  : size of code (feature maps)
-- kw              : width of convolutional kernel
-- kh              : height of convolutional kernel
-- iw              : width of input patches
-- ih              : height of input patches
-- lambda          : sparsity coefficient
-- params          : optim.FistaLS parameters
function FistaL1:__init(freconstruction, creconstruction, lambda, params)

   parent.__init(self)

   -----------------------------------------
   -- sparsity coefficient
   -----------------------------------------
   self.lambda = lambda

   -----------------------------------------
   -- dictionary has to be a linear function
   -----------------------------------------
   self.D = freconstruction

   ----------------------------------------------------
   -- reconstruction cost has to be convex and smooth
   ----------------------------------------------------
   self.Fcost = creconstruction

   -----------------------------------------
   -- L1 sparsity cost
   -----------------------------------------
   self.Gcost = nn.L1Cost()

   -- this is going to be set at each forward call.
   self.input = nil
   -- this is going to be passed to optim.FistaLS (this has to be initialized before being used)
   self.code = torch.Tensor()

   -- Now I need a function to pass along as f
   -- input is code, do reconstruction, calculate cost
   -- and possibly derivatives too
   self.f = function(x, mode)
      local code = x
      local gradx = nil
      local input = self.input

      -- forward function evaluation
      local reconstruction = self.D:updateOutput(code)
      local fval = self.Fcost:updateOutput(reconstruction, input)
      fval = fval * 0.5

      -- derivative wrt code
      if mode and mode:match('dx') then
         local gradr = self.Fcost:updateGradInput(reconstruction, input)
         gradr:mul(0.5)
         gradx = self.D:updateGradInput(code, gradr)
      end
      return fval, gradx
   end

   -- Next, we need function g that will be the non-smooth function
   self.g = function(x)
      local code = x
      local gradx = nil
      local fval = self.lambda * self.Gcost:updateOutput(code)
      if mode and mode:match('dx') then
         gradx = self.Gcost:updateGradInput(code)
         gradx:mul(self.lambda)
      end
      return fval, gradx
   end

   -- Finally we need argmin_x Q(x,y)
   self.pl = function(x, L)
      local code = x
      code:shrinkage(self.lambda/L)
   end

   -- this is for keeping parameters related to fista algorithm
   self.params = params or {}
   -- related to FISTA
   self.params.L = self.params.L or 0.1
   self.params.Lstep = self.params.Lstep or 1.5
   self.params.maxiter = self.params.maxiter or 50
   self.params.maxline = self.params.maxline or 20
   self.params.errthres = self.params.errthres or 1e-4
   self.params.doFistaUpdate = true

   self:reset()
   self.gradInput = nil
end

function FistaL1:reset(stdv)
   self.D:reset(stdv)
end

function FistaL1:parameters()
   return self.D:parameters()
end

function FistaL1:initDiagHessianParameters()
   if not self.D.initDiagHessianParameters then
      error('reconstruction module does not support hessian approximation')
   end
   self.D:initDiagHessianParameters()
end

-- we do inference in forward
function FistaL1:updateOutput(input,icode)
   self.input = input
   -- init code to all zeros
   --self.code:fill(0)
   self.code:copy(icode)
   -- do fista solution
   local oldL = self.params.L
   local code, h = optim.FistaLS(self.f, self.g, self.pl, self.code, self.params)
   local fval = h[#h].F

   -- let's just half the params.L (eq. to double learning rate)
   if oldL == self.params.L then
      self.params.L = math.max(0.1,self.params.L / 2)
   end

   return fval, h
end

-- no grad output, because we are unsup
-- d(||Ax-b||+lam||x||_1)/dx
function FistaL1:updateGradInput(input)
   -- calculate grad wrt to (x) which is code.
   if self.gradInput then
      local fval, gradf = self.fista.f(self.code,'dx')
      local gval, gradg = self.fista.g(self.code,'dx')
      self.gradInput:resizeAs(gradf):copy(gradf):add(gradg)
   end
   return self.gradInput
end

-- no grad output, because we are unsup
-- d(||Ax-b||+lam||x||_1)/dA
function FistaL1:accGradParameters(input)
   self.Fcost:updateGradInput(self.D.output,input)
   self.Fcost.gradInput:mul(0.5)
   self.D:accGradParameters(self.code, self.Fcost.gradInput)
end

function FistaL1:updateDiagHessianInput(input)

end

function FistaL1:accDiagHessianParameters(input)
   self.Fcost:updateDiagHessianInput(self.D.output, input)
   self.Fcost.diagHessianInput:mul(0.5)
   self.D:accDiagHessianParameters(self.code, self.Fcost.diagHessianInput)
end

function FistaL1:zeroGradParameters()
   self.D:zeroGradParameters()
end

function FistaL1:updateParameters(learningRate)
   self.D:updateParameters(learningRate)
end

function FistaL1:normalize()
   -- normalize the dictionary
   local w = self.D.weight
   if not w or w:dim() < 2 then return end

   if w:dim() == 5 then
      for i=1,w:size(1) do
         local keri = w:select(1,i)
         for j=1,w:size(2) do
            local kerj = keri:select(1,j)
            for k=1,w:size(3) do
               local ker = kerj:select(1,k)
               ker:div(ker:norm()+1e-12)
            end
         end
      end
   elseif w:dim() == 4 then
      for i=1,w:size(1) do
         for j=1,w:size(2) do
            local k=w:select(1,i):select(1,j)
            k:div(k:norm()+1e-12)
         end
      end
   elseif w:dim() == 3 then
      for i=1,w:size(1) do
         local k=w:select(1,i)
         k:div(k:norm()+1e-12)
      end
   elseif w:dim() == 2 then
      for i=1,w:size(2) do
         local k=w:select(2,i)
         k:div(k:norm()+1e-12)
      end
   else
      error('I do not know what kind of weight matrix this is')
   end
end
